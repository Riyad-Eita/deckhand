import Foundation
import Testing
@testable import DeckhandCore

/// The permission prompt MCP server, run for real with python3 here: a request waits in its folder, the app's answer
/// lets it through or refuses it with a reason, and no answer in time refuses it.
@Suite struct PermissionPromptTests {
    func setUp(timeout: Int) throws -> (MCPClient, String, String) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dh-ask-\(UUID().uuidString)").path
        let script = FileManager.default.temporaryDirectory.appending(path: "dh-approve-\(UUID().uuidString).py").path
        try PermissionPrompt.script.write(toFile: script, atomically: true, encoding: .utf8)
        let channel = try LocalProcessChannel(command: "python3 -u '\(script)' '\(dir)' \(timeout)")
        return (MCPClient(name: "deckhand", transport: StdioMCPTransport(channel: channel)), dir, script)
    }

    func waitForRequest(_ dir: String) async throws -> PermissionPrompt.Request {
        for _ in 0..<100 {
            let out = try await LocalShell().run(PermissionPrompt.pendingCommand(directory: dir), timeout: .seconds(5)).stdout
            if let r = PermissionPrompt.parsePending(out).first { return r }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MCPError("no request")
    }

    @Test func allowAndDenyComeBackToClaudeCode() async throws {
        let (client, dir, script) = try setUp(timeout: 30)
        defer { try? FileManager.default.removeItem(atPath: dir); try? FileManager.default.removeItem(atPath: script) }
        #expect(try await client.tools().map(\.name) == ["approve"])

        async let allowed = client.call("approve", arguments: ["tool_name": "Bash", "input": ["command": "systemctl restart nginx"]])
        let r = try await waitForRequest(dir)
        #expect(r.tool == "Bash" && r.input["command"]?.stringValue == "systemctl restart nginx")
        _ = try await LocalShell().run(try #require(PermissionPrompt.answerCommand(directory: dir, id: r.id, allow: true)), timeout: .seconds(5))
        let a = try JSONValue.parse(try await allowed.text)
        #expect(a["behavior"] == "allow" && a["updatedInput"]?["command"] == "systemctl restart nginx")
        #expect(PermissionPrompt.parsePending(try await LocalShell().run(PermissionPrompt.pendingCommand(directory: dir), timeout: .seconds(5)).stdout).isEmpty)

        async let denied = client.call("approve", arguments: ["tool_name": "Bash", "input": ["command": "rm -rf /var/www"]])
        let r2 = try await waitForRequest(dir)
        _ = try await LocalShell().run(try #require(PermissionPrompt.answerCommand(directory: dir, id: r2.id, allow: false, message: "Not the live site, use staging")), timeout: .seconds(5))
        let d = try JSONValue.parse(try await denied.text)
        #expect(d["behavior"] == "deny" && d["message"] == "Not the live site, use staging")
        await client.close()
    }

    @Test func noAnswerInTimeIsADenyWithAReason() async throws {
        let (client, dir, script) = try setUp(timeout: 1)
        defer { try? FileManager.default.removeItem(atPath: dir); try? FileManager.default.removeItem(atPath: script) }
        let r = try JSONValue.parse(try await client.call("approve", arguments: ["tool_name": "Write", "input": ["file_path": "/etc/hosts"]]).text)
        #expect(r["behavior"] == "deny")
        #expect(r["message"]?.stringValue?.contains("No answer") == true)
        #expect(PermissionPrompt.parsePending(try await LocalShell().run(PermissionPrompt.pendingCommand(directory: dir), timeout: .seconds(5)).stdout).isEmpty)
        await client.close()
    }

    @Test func onlyEditRunsAsk() {
        var o = CLIOptions(); o.askDirectory = "~/.deckhand/runs/x.ask"
        let edit = ServerCLIRun.command(.claudeCode, prompt: "hi", workingDirectory: "/srv", sessionID: nil, access: .edit, options: o)
        #expect(edit.contains("--permission-prompt-tool mcp__deckhand__approve") && edit.contains("deckhand-approve.py"))
        #expect(edit.contains(#"${DH_ASK:+--mcp-config "$DH_CFG""#))
        for access in [CLIAccess.readOnly, .full] {
            #expect(!ServerCLIRun.command(.claudeCode, prompt: "hi", workingDirectory: "/srv", sessionID: nil, access: access, options: o).contains("permission-prompt-tool"))
        }
        #expect(!ServerCLIRun.command(.codex, prompt: "hi", workingDirectory: "/srv", sessionID: nil, access: .edit, options: o).contains("permission-prompt-tool"))
        #expect(PermissionPrompt.answerCommand(directory: "/x", id: "../../etc", allow: true) == nil)
        #expect(PermissionPrompt.parsePending("@@req abc\n{\"id\":\"../x\",\"tool\":\"Bash\"}\n").isEmpty)
    }

    /// The shell part works: with python3 the flags are there, the config is one argument.
    @Test func flagsExpandToOneConfigArgument() async throws {
        let cmd = "HOME=/home/me; " + PermissionPrompt.prefix(directory: "~/.deckhand/runs/r1.ask").replacingOccurrences(of: PermissionPrompt.installCommand + "; ", with: "")
            + "for a in" + PermissionPrompt.claudeFlags + "; do echo \"[$a]\"; done"
        let out = try await LocalShell().run(cmd, timeout: .seconds(5)).stdout.split(separator: "\n").map(String.init)
        #expect(out.count == 4)
        #expect(out[0] == "[--mcp-config]" && out[2] == "[--permission-prompt-tool]")
        #expect(out[1].hasPrefix("[{\"mcpServers\""))
        let config = try JSONValue.parse(String(out[1].dropFirst().dropLast()))
        #expect(config["mcpServers"]?["deckhand"]?["args"] == ["/home/me/.deckhand/bin/deckhand-approve.py", "/home/me/.deckhand/runs/r1.ask", "900"])
    }
}
