import Foundation
import Testing
@testable import DeckhandCore

@Suite struct WebResearchTests {
    @Test func toolsPerModel() {
        let new = WebResearch.serverTools(model: "claude-opus-5-5")
        #expect(new.map { $0["type"]?.stringValue } == ["web_search_20260209", "web_fetch_20260209"])
        #expect(WebResearch.serverTools(model: "anthropic/claude-sonnet-5-5").count == 2)
        #expect(WebResearch.serverTools(model: "claude-haiku-5-5").map { $0["type"]?.stringValue } == ["web_search_20250305"])
        // Only when switched on, appended after the agent's own tools.
        var config = ProviderConfig(kind: .anthropic, model: "claude-opus-5-5", apiKey: "k")
        let req = ChatRequest(system: "s", messages: [.user("hi")], tools: [ToolSpec(name: "run_command", description: "d", inputSchema: ["type": "object"])])
        #expect(AnthropicProvider(config: config).body(for: req)["tools"]?.arrayValue?.count == 1)
        config.webResearch = true
        let tools = AnthropicProvider(config: config).body(for: req)["tools"]?.arrayValue ?? []
        #expect(tools.map { $0["name"]?.stringValue } == ["run_command", "web_search", "web_fetch"])
    }

    /// A streamed reply with a search: the server tool's input is kept, the result goes back verbatim, sources show.
    @Test func streamedSearchIsKeptAndSourcesFound() throws {
        var d = AnthropicStreamDecoder()
        let events = [
            #"{"type":"message_start","message":{"usage":{"input_tokens":10}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"nginx 1.29 "}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"changes\"}"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[{"type":"web_search_result","title":"nginx changes","url":"https://nginx.org/en/CHANGES","encrypted_content":"x"},{"type":"web_search_result","title":"nginx changes","url":"https://nginx.org/en/CHANGES","encrypted_content":"y"}]}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"1.29 adds HTTP/3 fixes."}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":20}}"#,
            #"{"type":"message_stop"}"#,
        ]
        for e in events { _ = try d.consume(SSEParser.Event(event: nil, data: e)) }
        guard case .completed(let message, _, _)? = try d.finish().first else { Issue.record("no message"); return }
        guard case .opaque(_, let use) = message.blocks[0] else { Issue.record("server tool use lost"); return }
        #expect(use["input"]?["query"] == "nginx 1.29 changes")
        let encoded = AnthropicProvider.encode(message)
        #expect(encoded["content"]?.arrayValue?.map { $0["type"]?.stringValue } == ["server_tool_use", "web_search_tool_result", "text"])
        let a = WebResearch.activity(in: message)
        #expect(a.queries == ["nginx 1.29 changes"])
        #expect(a.sources.map(\.url) == ["https://nginx.org/en/CHANGES"] && a.sources[0].host == "nginx.org")
        // An error result is reported, not shown as a source.
        let failed = Message(role: .assistant, blocks: [.opaque(provider: "anthropic", value: ["type": "web_search_tool_result", "content": ["type": "web_search_tool_result_error", "error_code": "max_uses_exceeded"]])])
        #expect(WebResearch.activity(in: failed).errors == ["max_uses_exceeded"])
    }

    @Test func fetchFallbackIsSafe() async throws {
        #expect(FetchURLTool.command(url: "file:///etc/passwd") == nil)
        #expect(FetchURLTool.command(url: "https://example.com/a'b") == nil)
        #expect(FetchURLTool.command(url: "https://example.com/docs")?.contains("curl -sSL --max-time 25") == true)
        #expect(FetchURLTool().isReadOnly)
    }
}

/// Opt-in: DECKHAND_NET_TEST=1. The curl fallback reads a real page as text.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_NET_TEST"] != nil))
struct WebResearchLiveTests {
    @Test func fetchesExampleDotCom() async throws {
        let text = try await FetchURLTool().execute(["url": "https://example.com"], shell: LocalShell())
        #expect(text.contains("Example Domain"))
        #expect(!text.contains("<html"))
    }
}
