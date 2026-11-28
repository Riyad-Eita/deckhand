import Foundation
import Testing
@testable import DeckhandCore

@Suite struct SpendTests {
    func reply(_ model: String?, input: Int, output: Int) -> Message {
        var m = Message(role: .assistant, blocks: [.text("ok")])
        m.model = model
        m.usage = Usage(inputTokens: input, outputTokens: output)
        return m
    }

    @Test func tokensAndCostPerTask() {
        let messages = [Message.user("hi"), reply("claude-sonnet-5-5", input: 1_000_000, output: 100_000), reply("claude-haiku-5-5", input: 0, output: 1_000_000)]
        let t = Spend.total(messages)
        #expect(t.tokens == 2_100_000)
        #expect(abs(t.cost - (2 + 1 + 0.5)) < 0.0001)
        #expect(!t.unpriced)
        #expect(Spend.label(t) == "2100.0k tokens · $3.50")
        // A model without a known price: tokens count, the cost is a lower bound.
        let mixed = Spend.total(messages + [reply("some-local-model", input: 10, output: 5)])
        #expect(mixed.unpriced && Spend.label(mixed).contains("≥ $3.50"))
        #expect(Spend.label(Spend.total([reply("x", input: 100, output: 20)])) == "120 tokens")
    }

    @Test func limitsWarnThenStop() {
        let limits = Spend.Limits(perTaskUSD: 1, perDayUSD: 10)
        #expect(Spend.check(task: 0.5, day: 2, limits: limits) == .ok)
        guard case .warn(let w) = Spend.check(task: 0.85, day: 2, limits: limits) else { Issue.record("no warning"); return }
        #expect(w.contains("$1.00"))
        guard case .stop(let s) = Spend.check(task: 1.0, day: 2, limits: limits) else { Issue.record("no stop"); return }
        #expect(s.contains("task"))
        guard case .stop(let d) = Spend.check(task: 0.1, day: 10.5, limits: limits) else { Issue.record("no day stop"); return }
        #expect(d.contains("Today"))
        guard case .warn = Spend.check(task: 0, day: 8.5, limits: limits) else { Issue.record("no day warning"); return }
        #expect(Spend.check(task: 999, day: 999, limits: Spend.Limits()) == .ok)
        #expect(Spend.Limits(perTaskUSD: 0, perDayUSD: -1).isEmpty)
        #expect(Spend.dayKey(Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian)).count == 10)
    }

    /// A stopped turn leaves tool calls without results; the next turn closes them so the model API accepts it.
    @Test func interruptedToolCallsAreClosed() {
        let a = ToolCall(id: "a", name: "run_command", input: ["command": "ls"])
        let b = ToolCall(id: "b", name: "read_file", input: ["path": "x"])
        let asked = Message(role: .assistant, blocks: [.text("Looking"), .toolUse(a), .toolUse(b)])
        // Nothing came back at all.
        let closed = Agent.closeInterrupted([.user("go"), asked])
        #expect(closed.count == 3)
        let ids = closed[2].blocks.compactMap { if case .toolResult(let r) = $0, r.isError { r.toolUseID } else { nil } }
        #expect(ids == ["a", "b"])
        // One result came back: the other is added to the same message.
        let partial = Message(role: .user, blocks: [.toolResult(ToolResult(toolUseID: "a", content: "file"))])
        let fixed = Agent.closeInterrupted([.user("go"), asked, partial, .user("again")])
        #expect(fixed.count == 4)
        let results = fixed[2].blocks.compactMap { if case .toolResult(let r) = $0 { r.toolUseID } else { nil } }
        #expect(Set(results) == ["a", "b"])
        // A complete history stays as it is.
        let done = Message(role: .user, blocks: [.toolResult(ToolResult(toolUseID: "a", content: "1")), .toolResult(ToolResult(toolUseID: "b", content: "2"))])
        let go = Message.user("go")
        #expect(Agent.closeInterrupted([go, asked, done]) == [go, asked, done])
    }
}
