import Foundation
import Testing
@testable import DeckhandCore

/// The API key of a server-side own-key run: sent over stdin, in the run's environment, gone from disk before the CLI starts.
@Suite struct RunKeyTests {
    @Test func providersAndVariables() {
        #expect(RunKey.cli(for: .anthropic) == .claudeCode && RunKey.cli(for: .openAI) == .codex)
        #expect(RunKey.cli(for: .openRouter) == nil && RunKey.cli(for: .custom) == nil)
        #expect(RunKey.variable(for: .claudeCode) == "ANTHROPIC_API_KEY" && RunKey.variable(for: .codex) == "CODEX_API_KEY")
        #expect(!RunKey.prepareCommand(DetachedRun(id: "r1")).contains("sk-"))
    }

    /// In a throwaway HOME on this Mac: the key reaches the command's environment, never its arguments, and no file stays.
    @Test func keyReachesTheRunAndLeavesNoFile() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "dh-key-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let run = DetachedRun(id: "r\(Int.random(in: 1000...9999))")
        let key = "test-key-\(UUID().uuidString)"
        let sh = LocalShell()
        let prepared = try await sh.run("export HOME='\(home)'; printf '%s\\n' '\(key)' | { \(RunKey.prepareCommand(run)); }", timeout: .seconds(10)).stdout
        #expect(prepared.contains("@@key ok"))
        let mode = try await sh.run("stat -f %Lp '\(home)/.deckhand/runs/\(run.id).key/key'", timeout: .seconds(5)).stdout
        #expect(mode.trimmingCharacters(in: .whitespacesAndNewlines) == "600")
        let probe = #"echo "env=${ANTHROPIC_API_KEY}"; ls "$HOME/.deckhand/runs/"*.key 2>/dev/null | wc -l | tr -d ' '"#
        let out = try await sh.run("export HOME='\(home)'; " + RunKey.wrap(probe, run: run, cli: .claudeCode), timeout: .seconds(10)).stdout
        #expect(out.contains("env=\(key)"))
        #expect(out.hasSuffix("0\n"), "the key file is gone while the command runs")
        #expect(!FileManager.default.fileExists(atPath: "\(home)/.deckhand/runs/\(run.id).key"), "the folder is removed at the end")
    }
}

@Suite struct RunKeyErrorTests {
    /// Claude Code's answer to a bad key in an own-key run points to the key, not to logging in.
    @Test func aRefusedKeyIsNamed() throws {
        var d = ClaudeCodeEventDecoder()
        _ = try d.consume(line: #"{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key · Fix external API key"}"#)
        #expect(d.failure?.message.contains("API key was refused") == true)
        #expect(ClaudeCodeEventDecoder.friendly("Invalid API key · Please run /login").contains("not logged in"))
        #expect(RunKey.wrap("true", run: DetachedRun(id: "x"), cli: .codex).contains("export CODEX_API_KEY="))
    }
}
