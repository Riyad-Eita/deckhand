import Foundation
import Testing
@testable import DeckhandCore

@Suite struct SSEParserTests {
    @Test func parsesEventsAndMultilineData() {
        var p = SSEParser()
        let lines = ["event: ping", "data: {\"a\":1}", "", ": comment", "data: one", "data: two", "", "data: tail"]
        var events: [SSEParser.Event] = []
        for l in lines { if let e = p.feed(line: l) { events.append(e) } }
        if let e = p.flush() { events.append(e) }
        #expect(events == [
            .init(event: "ping", data: "{\"a\":1}"),
            .init(event: nil, data: "one\ntwo"),
            .init(event: nil, data: "tail"),
        ])
    }

    @Test func stripsCarriageReturns() {
        var p = SSEParser()
        _ = p.feed(line: "data: x\r")
        #expect(p.feed(line: "\r") == .init(event: nil, data: "x"))
    }
}

@Suite struct AnthropicDecoderTests {
    static let stream: [String] = [
        #"{"type":"message_start","message":{"usage":{"input_tokens":120,"output_tokens":1}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Check disk."}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Let me "}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"look."}}"#,
        #"{"type":"content_block_stop","index":1}"#,
        #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"run_command","input":{}}}"#,
        #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"command\": \"df"}}"#,
        #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":" -h\"}"}}"#,
        #"{"type":"content_block_stop","index":2}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#,
        #"{"type":"message_stop"}"#,
    ]

    @Test func decodesThinkingTextAndToolUse() throws {
        var d = AnthropicStreamDecoder()
        var events: [ProviderEvent] = []
        for s in Self.stream { events += try d.consume(.init(event: nil, data: s)) }
        #expect(d.isFinished)
        events += try d.finish()
        #expect(events.contains(.textDelta("look.")))
        #expect(events.contains(.toolCallStarted(id: "toolu_1", name: "run_command")))
        guard case .completed(let m, let stop, let usage) = events.last else { Issue.record("no completion"); return }
        #expect(stop == .toolUse)
        #expect(usage.inputTokens == 120 && usage.outputTokens == 42)
        #expect(m.blocks[0] == .thinking(text: "Check disk.", signature: "sig123"))
        #expect(m.text == "Let me look.")
        #expect(m.toolCalls == [ToolCall(id: "toolu_1", name: "run_command", input: ["command": "df -h"])])
    }

    @Test func invalidToolJSONIsFlagged() throws {
        var d = AnthropicStreamDecoder()
        _ = try d.consume(.init(event: nil, data: #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"x","input":{}}}"#))
        _ = try d.consume(.init(event: nil, data: #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"a\": \"unterminated"}}"#))
        guard case .completed(let m, _, _) = try d.finish().last else { Issue.record("no completion"); return }
        #expect(m.toolCalls.first?.input["INVALID_JSON"]?.stringValue == "{\"a\": \"unterminated")
    }

    @Test func requestBodyRoundTripsThinkingAndToolResults() throws {
        let p = AnthropicProvider(config: ProviderConfig(kind: .anthropic, model: "claude-opus-5-5", apiKey: "k", effort: "high"))
        let history: [Message] = [
            .user("check disk"),
            Message(role: .assistant, blocks: [
                .thinking(text: "t", signature: "s"),
                .toolUse(ToolCall(id: "toolu_1", name: "run_command", input: ["command": "df"])),
            ]),
            Message(role: .user, blocks: [.toolResult(ToolResult(toolUseID: "toolu_1", content: "ok"))]),
        ]
        let body = p.body(for: ChatRequest(system: "sys", messages: history, tools: ServerTools.all(workingDirectory: "~").map(\.spec)))
        #expect(body["model"] == "claude-opus-5-5")
        #expect(body["fallbacks"] == "default")
        #expect(body["output_config"]?["effort"] == "high")
        #expect(body["tools"]?.arrayValue?.first?["eager_input_streaming"] == true)
        let assistant = body["messages"]?.arrayValue?[1]["content"]?.arrayValue
        #expect(assistant?[0]["signature"] == "s")
        #expect(body["messages"]?.arrayValue?[2]["content"]?.arrayValue?[0]["tool_use_id"] == "toolu_1")
        let request = try p.makeURLRequest(ChatRequest(system: "", messages: [.user("hi")], tools: []))
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test func haikuHasNoFallback() {
        let p = AnthropicProvider(config: ProviderConfig(kind: .anthropic, model: "claude-haiku-5-5", apiKey: "k"))
        #expect(p.body(for: ChatRequest(system: "", messages: [.user("x")], tools: []))["fallbacks"] == nil)
    }
}

@Suite struct OpenAIDecoderTests {
    @Test func decodesToolCallsAcrossChunks() throws {
        let chunks = [
            #"{"choices":[{"delta":{"role":"assistant","content":"On it."}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"read_file","arguments":""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"a.txt\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#,
            "[DONE]",
        ]
        var d = OpenAIChatStreamDecoder()
        var events: [ProviderEvent] = []
        for c in chunks { events += try d.consume(.init(event: nil, data: c)) }
        #expect(d.isFinished)
        events += try d.finish()
        guard case .completed(let m, let stop, let usage) = events.last else { Issue.record("no completion"); return }
        #expect(stop == .toolUse)
        #expect(usage.outputTokens == 5)
        #expect(m.text == "On it.")
        #expect(m.toolCalls == [ToolCall(id: "call_a", name: "read_file", input: ["path": "a.txt"])])
    }

    @Test func encodesToolResultsAsToolMessages() {
        let m = Message(role: .user, blocks: [.toolResult(ToolResult(toolUseID: "c1", content: "boom", isError: true))])
        let out = OpenAIChatProvider.encode(m)
        #expect(out.count == 1)
        #expect(out[0]["role"] == "tool")
        #expect(out[0]["content"] == "ERROR: boom")
    }
}

@Suite struct ServerToolTests {
    let shell = LocalShell()

    func tool(_ name: String, cwd: String) -> any AgentTool {
        ServerTools.all(workingDirectory: cwd).first { $0.spec.name == name }!
    }

    func tempDir() throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "deckhand-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test func writeReadEditSearchList() async throws {
        let dir = try tempDir()
        let content = "alpha\nbeta 'quoted' $HOME\ngamma\n"
        _ = try await tool("write_file", cwd: dir).execute(["path": "sub/f.txt", "content": .string(content)], shell: shell)
        #expect(try String(contentsOfFile: dir + "/sub/f.txt", encoding: .utf8) == content)

        let read = try await tool("read_file", cwd: dir).execute(["path": "sub/f.txt", "offset": 2, "limit": 1], shell: shell)
        #expect(read == "     2\tbeta 'quoted' $HOME\n")

        _ = try await tool("edit_file", cwd: dir).execute(
            ["path": "sub/f.txt", "old_string": "gamma", "new_string": "delta"], shell: shell)
        #expect(try String(contentsOfFile: dir + "/sub/f.txt", encoding: .utf8).contains("delta"))

        await #expect(throws: ToolError.self) {
            _ = try await tool("edit_file", cwd: dir).execute(
                ["path": "sub/f.txt", "old_string": "nope", "new_string": "x"], shell: shell)
        }

        let found = try await tool("search", cwd: dir).execute(["pattern": "del+ta"], shell: shell)
        #expect(found.contains("f.txt:3:delta"))

        let listing = try await tool("list_directory", cwd: dir).execute(["path": "sub"], shell: shell)
        #expect(listing.contains("f.txt"))
    }

    @Test func runCommandReportsExitCodeAndCwd() async throws {
        let dir = try tempDir()
        let out = try await tool("run_command", cwd: dir).execute(["command": "pwd; echo err >&2; exit 3"], shell: shell)
        #expect(out.hasPrefix("exit code: 3"))
        #expect(out.contains(dir.components(separatedBy: "/").last!))
        #expect(out.contains("stderr:\nerr"))
    }
}

/// A provider that replays scripted turns.
final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    var turns: [[ProviderEvent]]
    var requests: [ChatRequest] = []
    init(_ turns: [[ProviderEvent]]) { self.turns = turns }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        requests.append(request)
        let events = turns.isEmpty ? [] : turns.removeFirst()
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            c.finish()
        }
    }
}

@Suite struct AgentLoopTests {
    @Test func runsToolThenAnswers() async throws {
        let call = ToolCall(id: "t1", name: "run_command", input: ["command": "echo hello"])
        let provider = ScriptedProvider([
            [.completed(Message(role: .assistant, blocks: [.toolUse(call)]), .toolUse, Usage())],
            [.textDelta("Done."), .completed(Message(role: .assistant, blocks: [.text("Done.")]), .endTurn, Usage())],
        ])
        let agent = Agent(
            provider: provider, shell: LocalShell(), tools: ServerTools.all(workingDirectory: "/tmp"),
            policy: .auto, system: "s", approve: { _, _ in .allow })
        var events: [AgentEvent] = []
        for try await e in agent.run(history: [], userMessage: .user("say hello")) { events.append(e) }
        #expect(events.last == .finished(.endTurn))
        let second = provider.requests[1].messages
        #expect(second.count == 3)
        guard case .toolResult(let r) = second[2].blocks[0] else { Issue.record("no tool result"); return }
        #expect(r.content.contains("hello"))
        #expect(!r.isError)
    }

    @Test func deniedCallReturnsErrorResult() async throws {
        let call = ToolCall(id: "t1", name: "write_file", input: ["path": "/tmp/x", "content": "y"])
        let provider = ScriptedProvider([
            [.completed(Message(role: .assistant, blocks: [.toolUse(call)]), .toolUse, Usage())],
            [.completed(Message(role: .assistant, blocks: [.text("ok")]), .endTurn, Usage())],
        ])
        let agent = Agent(
            provider: provider, shell: LocalShell(), tools: ServerTools.all(workingDirectory: "/tmp"),
            policy: .autoRead, system: "s", approve: { _, readOnly in readOnly ? .allow : .deny(reason: "no") })
        for try await _ in agent.run(history: [], userMessage: .user("x")) {}
        guard case .toolResult(let r) = provider.requests[1].messages[2].blocks[0] else { Issue.record("no result"); return }
        #expect(r.isError)
        #expect(r.content.contains("declined"))
    }

    @Test func truncatedToolCallIsNotRun() async throws {
        let call = ToolCall(id: "t1", name: "run_command", input: ["command": .string("touch /tmp/should-not-exist-\(UUID())")])
        let provider = ScriptedProvider([
            [.completed(Message(role: .assistant, blocks: [.toolUse(call)]), .maxTokens, Usage())],
            [.completed(Message(role: .assistant, blocks: [.text("ok")]), .endTurn, Usage())],
        ])
        let agent = Agent(
            provider: provider, shell: LocalShell(), tools: ServerTools.all(workingDirectory: "/tmp"),
            policy: .auto, system: "s", approve: { _, _ in .allow })
        var ran = false
        for try await e in agent.run(history: [], userMessage: .user("x")) { if case .toolRunning = e { ran = true } }
        #expect(!ran)
    }
}
