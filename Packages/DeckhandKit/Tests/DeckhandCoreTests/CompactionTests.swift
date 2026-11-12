import Foundation
import Testing
@testable import DeckhandCore

struct CompactionTests {
    func long(_ n: Int) -> String { String(repeating: "x", count: n) }

    @Test func summarizesOldStepsAndKeepsRecentOnes() async throws {
        // A long history: user / assistant tool call / tool result, ten times, each big.
        var history: [Message] = [.user("Upgrade the shop")]
        for i in 0..<10 {
            let call = ToolCall(id: "t\(i)", name: "run_command", input: ["command": .string("step \(i)")])
            history.append(Message(role: .assistant, blocks: [.toolUse(call)]))
            history.append(Message(role: .user, blocks: [.toolResult(ToolResult(toolUseID: "t\(i)", content: long(4_000)))]))
        }
        let provider = ScriptedProvider([
            [.completed(Message(role: .assistant, blocks: [.text("- Goal: upgrade the shop\n- Ran steps 0–7")]), .endTurn, Usage())],
            [.completed(Message(role: .assistant, blocks: [.text("Done.")]), .endTurn, Usage())],
        ])
        var agent = Agent(provider: provider, shell: LocalShell(), tools: [], policy: .auto, system: "s", approve: { _ in .allow })
        agent.contextBudget = 5_000
        var compacted: (String, Int)?
        for try await e in agent.run(history: history, userMessage: .user("go on")) {
            if case .compacted(let s, let d) = e { compacted = (s, d) }
        }
        let c = try #require(compacted)
        #expect(c.0.contains("Goal: upgrade the shop"))
        #expect(provider.requests.count == 2)
        #expect(provider.requests[0].tools.isEmpty && provider.requests[0].system.contains("Summarize"))
        let sent = provider.requests[1].messages
        #expect(sent[0].text.hasPrefix(Compaction.marker) && sent[1].role == .assistant)
        #expect(sent.count == 2 + (history.count + 1 - c.1))          // summary pair + the kept tail
        #expect(sent[2].role == .assistant)                             // the kept part starts with an assistant turn
        // Every tool result kept has its tool call kept too.
        let calls = Set(sent.flatMap { $0.toolCalls.map(\.id) })
        let results = sent.flatMap { $0.blocks.compactMap { if case .toolResult(let r) = $0 { r.toolUseID } else { nil } } }
        #expect(results.allSatisfy(calls.contains))
        #expect(Compaction.estimate(sent) < Compaction.estimate(history))
    }

    @Test func smallHistoriesAreLeftAlone() async throws {
        let provider = ScriptedProvider([[.completed(Message(role: .assistant, blocks: [.text("Hi")]), .endTurn, Usage())]])
        let agent = Agent(provider: provider, shell: LocalShell(), tools: [], policy: .auto, system: "s", approve: { _ in .allow })
        for try await _ in agent.run(history: [], userMessage: .user("hello")) {}
        #expect(provider.requests.count == 1)
    }
}
