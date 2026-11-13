import Foundation
import Testing
@testable import DeckhandCore

@Suite struct ModelRouterTests {
    typealias R = ModelRouter

    @Test func classifiesTasks() {
        #expect(R.classify("What's the capital of Portugal?") == .quick)
        #expect(R.classify("How many days until Christmas?") == .quick)
        #expect(R.classify("Summarize this article for me: the city council met on Tuesday…") == .writing)
        #expect(R.classify("Write an email to my landlord about the broken heating") == .writing)
        #expect(R.classify("Why does this throw?\n```swift\nlet x: Int = nil\n```") == .reasoning)
        #expect(R.classify("Write a bash script that rotates logs older than 7 days") == .code)
        #expect(R.classify("Fix the bug in deploy.sh, it exits early") == .code)
        #expect(R.classify("Should I move our Postgres to a managed service or keep running it on the VPS? We have about 40 GB of data and two people on call.") == .reasoning)
        #expect(R.classify(String(repeating: "Long pasted text without a question. ", count: 80)) == .writing)
        #expect(R.classify("What's in this picture?", images: 1) == .writing)
    }

    @Test func tiersFromNames() {
        #expect(R.tier(of: "claude-haiku-5-5") == .small)
        #expect(R.tier(of: "claude-sonnet-5-5") == .medium)
        #expect(R.tier(of: "claude-opus-5-5") == .large)
        #expect(R.tier(of: "anthropic/claude-fable-5-2") == .large)
        #expect(R.tier(of: "gpt-5.1-mini") == .small)
        #expect(R.tier(of: "gpt-5.1") == .large)
        #expect(R.tier(of: "qwen3:0.6b") == .small)
        #expect(R.tier(of: "qwen3:8b") == .medium)
        #expect(R.tier(of: "llama3.1:70b") == .large)
        #expect(R.tier(of: "some-model") == .medium)
    }

    @Test func picksCheapestGoodEnough() {
        let haiku = R.Candidate(provider: .anthropic, model: "claude-haiku-5-5", price: ModelPrice.known("claude-haiku-5-5"))
        let sonnet = R.Candidate(provider: .anthropic, model: "claude-sonnet-5-5", price: ModelPrice.known("claude-sonnet-5-5"))
        let opus = R.Candidate(provider: .anthropic, model: "claude-opus-5-5", price: ModelPrice.known("claude-opus-5-5"))
        let all = [opus, sonnet, haiku]
        #expect(R.pick(for: .quick, among: all) == haiku)
        #expect(R.pick(for: .code, among: all) == sonnet)
        #expect(R.pick(for: .reasoning, among: all) == opus)
        #expect(R.pick(for: .quick, length: 9_000, among: all) == sonnet)

        // A local 8B model is free and good enough for code; a quick question goes to a small free one if there is one.
        let local8 = R.Candidate(provider: .custom, model: "qwen3:8b", price: .free)
        #expect(R.pick(for: .code, among: all + [local8]) == local8)
        #expect(R.pick(for: .quick, among: all + [local8]) == local8)
        #expect(R.pick(for: .reasoning, among: all + [local8]) == opus)

        // Unknown prices count as expensive; nothing big enough → the biggest.
        let unknown = R.Candidate(provider: .openAI, model: "gpt-5.1-mini")
        #expect(R.pick(for: .quick, among: [unknown, haiku]) == haiku)
        #expect(R.pick(for: .reasoning, among: [haiku, sonnet]) == sonnet)
        #expect(R.pick(for: .quick, among: []) == nil)
    }

    @Test func prices() throws {
        let opus = try #require(ModelPrice.known("claude-opus-5-5"))
        #expect(opus.cost(Usage(inputTokens: 1_000_000, outputTokens: 0)) == 4)
        #expect(opus.cost(Usage(inputTokens: 0, outputTokens: 100_000, cacheReadTokens: 1_000_000)) == 2.2)
        #expect(ModelPrice.known("anthropic/claude-sonnet-5-5")?.output == 10)
        #expect(ModelPrice.known("gpt-5.1") == nil)
        #expect(ModelPrice.format(0) == "free")
        #expect(ModelPrice.format(0.00042) == "$0.0004")
        #expect(ModelPrice.format(1.234) == "$1.23")
        #expect(ModelPrice.format(0.00001) == "<$0.0001")
    }

    @Test func messagesKeepModelAndUsage() throws {
        var m = Message(role: .assistant, blocks: [.text("hi")])
        m.model = "claude-haiku-5-5"; m.usage = Usage(inputTokens: 10, outputTokens: 2)
        let back = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(m))
        #expect(back.model == "claude-haiku-5-5" && back.usage?.outputTokens == 2)
        // Older stored messages without the fields still decode.
        let old = #"{"id":"\#(UUID().uuidString)","role":"assistant","blocks":[]}"#
        #expect(try JSONDecoder().decode(Message.self, from: Data(old.utf8)).model == nil)
    }
}
