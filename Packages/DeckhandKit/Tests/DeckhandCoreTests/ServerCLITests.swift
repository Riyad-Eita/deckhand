import Foundation
import Testing
@testable import DeckhandCore

@Suite struct ServerCLITests {
    func fixture(_ name: String) throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test func decodesCodexRun() throws {
        var d = CodexEventDecoder()
        var events: [AgentEvent] = []
        for line in try fixture("codex-exec") { events += try d.consume(line: line) }
        events += try d.finish()
        #expect(events.first == .sessionStarted("01a1c230-f616-7fc2-b236-ce270a781944"))
        let call = ToolCall(id: "item_1", name: "run_command", input: ["command": "uname -r"])
        #expect(events.contains(.toolRunning(call)))
        #expect(events.contains(.toolFinished(call, ToolResult(toolUseID: "item_1", content: "exit code: 0\n5.2.0\n"))))
        let texts = events.compactMap { if case .message(let m) = $0, m.role == .assistant { m.text } else { nil } }.filter { !$0.isEmpty }
        #expect(texts == ["I’ll check the kernel version.", "The kernel version is 5.2.0."])
        #expect(events.last == .finished(.endTurn))
    }

    @Test func codexFailureIsFriendly() throws {
        var d = CodexEventDecoder()
        _ = try d.consume(line: #"{"type":"error","message":"Re-connecting... 1/5"}"#)
        // The failure is reported when the stream ends (a limit-aware run may continue after a failed turn).
        _ = try d.consume(line: #"{"type":"turn.failed","error":{"message":"unexpected status 400 Bad Request: {\"detail\":\"The 'x' model requires a newer version of Codex.\"}"}}"#)
        #expect(throws: CLIError.self) { _ = try d.finish() }
        #expect(d.failure?.message.contains("too old") == true)
    }

    @Test func decodesClaudeCodeRun() throws {
        var d = ClaudeCodeEventDecoder()
        var events: [AgentEvent] = []
        for line in try fixture("claude-stream") { events += try d.consume(line: line) }
        events += try d.finish()
        #expect(events.first == .sessionStarted("5f0c7d2e-1111-4a1b-9d5e-000000000001"))
        let call = ToolCall(id: "toolu_01", name: "run_command", input: ["command": "uname -r"])
        #expect(events.contains(.toolFinished(call, ToolResult(toolUseID: "toolu_01", content: "5.2.0"))))
        #expect(events.last == .finished(.endTurn))
    }

    @Test func claudeNotLoggedIn() throws {
        var d = ClaudeCodeEventDecoder()
        _ = try d.consume(line: #"{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key · Please run /login"}"#)
        #expect(throws: CLIError.self) { _ = try d.finish() }
        #expect(d.failure?.message.contains("not logged in") == true)
    }

    @Test func unwrapsShellWrappers() {
        #expect(CodexEventDecoder.unwrap("/bin/bash -lc 'uname -r'") == "uname -r")
        #expect(CodexEventDecoder.unwrap(#"/bin/bash -lc "lscpu | rg '^CPU\\(s\\):' && echo \"x\"""#) == #"lscpu | rg '^CPU\(s\):' && echo "x""#)
        #expect(CodexEventDecoder.unwrap("ls -la") == "ls -la")
    }

    @Test func commandsQuoteAndResume() {
        let c = ServerCLIRun.command(.codex, prompt: "fix it's bug", workingDirectory: "~/app", sessionID: "abc", access: .edit)
        #expect(c == "cd ~/'app' && codex exec --json --skip-git-repo-check -s workspace-write resume 'abc' 'fix it'\\''s bug' < /dev/null")
        let k = ServerCLIRun.command(.claudeCode, prompt: "hi", workingDirectory: "/srv", sessionID: nil, access: .readOnly)
        #expect(k == "cd '/srv' && claude -p 'hi' --output-format stream-json --verbose --permission-mode plan < /dev/null")
    }

    @Test func runsThroughStreamingShell() async throws {
        let url = try #require(Bundle.module.url(forResource: "codex-exec", withExtension: "jsonl", subdirectory: "Fixtures"))
        // Fake "codex" by catting the fixture: exercise ServerCLIRun.run end to end with LocalShell.
        struct CatShell: StreamingShell {
            let path: String
            func run(_ command: String, timeout: Duration) async throws -> CommandResult { CommandResult(stdout: "") }
            func streamLines(_ command: String) -> AsyncThrowingStream<String, Error> { LocalShell().streamLines("cat '\(path)'") }
        }
        var last: AgentEvent?
        for try await e in ServerCLIRun.run(.codex, shell: CatShell(path: url.path), prompt: "x", workingDirectory: "/tmp", sessionID: nil, access: .readOnly) {
            last = e
        }
        #expect(last == .finished(.endTurn))
    }
}
