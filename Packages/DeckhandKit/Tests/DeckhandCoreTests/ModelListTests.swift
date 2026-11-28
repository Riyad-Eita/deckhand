import Foundation
import Testing
@testable import DeckhandCore

@Suite struct ModelListTests {
    @Test func requestsPerProvider() {
        let a = ModelList.request(ProviderConfig(kind: .anthropic, model: "", apiKey: "k"))
        #expect(a.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
        #expect(a.value(forHTTPHeaderField: "x-api-key") == "k" && a.value(forHTTPHeaderField: "anthropic-version") != nil)
        let o = ModelList.request(ProviderConfig(kind: .openAI, model: "", apiKey: "k"))
        #expect(o.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(o.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let local = ModelList.request(ProviderConfig(kind: .custom, baseURL: URL(string: "http://10.0.0.2:11434/v1"), model: "", apiKey: ""))
        #expect(local.url?.absoluteString == "http://10.0.0.2:11434/v1/models")
        #expect(local.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func parsesAnthropicNewestFirst() throws {
        let body = #"{"data":[{"type":"model","id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5","created_at":"2026-05-01T00:00:00Z"},{"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","created_at":"2026-09-01T00:00:00Z"}],"has_more":false}"#
        let models = try ModelList.parse(Data(body.utf8), kind: .anthropic)
        #expect(models.map(\.id) == ["claude-opus-5-5", "claude-haiku-5-5"])
        #expect(models[0].name == "Claude Opus 5.5")
        // Recommended ones that exist come first and are marked; the rest follows.
        let choices = ModelList.choices(live: models + [.init(id: "claude-test-1")], kind: .anthropic)
        #expect(choices.first?.id == "claude-opus-5-5" && choices.first?.recommended == true)
        #expect(choices.contains { $0.id == "claude-test-1" && !$0.recommended })
        #expect(ModelList.choices(live: nil, kind: .anthropic).map(\.id) == ProviderKind.anthropic.suggestedModels)
    }

    @Test func openAIDropsModelsThatCantChat() throws {
        let body = #"{"object":"list","data":[{"id":"gpt-5.1","created":1790000000},{"id":"text-embedding-3-large","created":1},{"id":"whisper-1","created":1},{"id":"gpt-5.1-mini","created":1780000000},{"id":"tts-1-hd","created":1}]}"#
        #expect(try ModelList.parse(Data(body.utf8), kind: .openAI).map(\.id) == ["gpt-5.1", "gpt-5.1-mini"])
    }

    @Test func openRouterSendsPrices() throws {
        let body = #"{"data":[{"id":"anthropic/claude-opus-5-5","name":"Claude Opus 5.5","created":1790000000,"pricing":{"prompt":"0.000004","completion":"0.00002"}}]}"#
        let m = try #require(try ModelList.parse(Data(body.utf8), kind: .openRouter).first)
        #expect(abs((m.price?.input ?? 0) - 4) < 0.0001 && abs((m.price?.output ?? 0) - 20) < 0.0001)
    }

    @Test func errorsExplainThemselves() {
        #expect(throws: LLMError.self) { try ModelList.parse(Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8), kind: .anthropic) }
        #expect(throws: (any Error).self) { try ModelList.parse(Data("<html>".utf8), kind: .openAI) }
    }
}

/// Opt-in: DECKHAND_NET_TEST=1. OpenRouter's public list (no key needed) parses, with prices.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_NET_TEST"] != nil))
struct ModelListLiveTests {
    @Test func openRouterLive() async throws {
        let (data, _) = try await URLSession.shared.data(for: ModelList.request(ProviderConfig(kind: .openRouter, model: "", apiKey: "")))
        let models = try ModelList.parse(data, kind: .openRouter)
        #expect(models.count > 20)
        #expect(models.contains { $0.id.hasPrefix("anthropic/") })
        #expect(models.filter { $0.price != nil }.count > 10)
    }
}
