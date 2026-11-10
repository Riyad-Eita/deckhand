import DeckhandCore
import Foundation
import Testing
@testable import DeckhandSSH

@Suite struct SSHKeyTests {
    @Test(arguments: ["", "deckhand@test", "deckhand@iphone-of-riad", "x"])
    func generatedKeyRoundTrips(comment: String) throws {
        let pair = SSHKeys.generateEd25519(comment: comment)
        #expect(pair.privateKey.contains("BEGIN OPENSSH PRIVATE KEY"))
        #expect(pair.publicKey.hasPrefix("ssh-ed25519 AAAA"))
        #expect(pair.publicKey.hasSuffix(" \(comment)"))
        #expect(SSHKeys.publicKeyLine(privateKey: pair.privateKey, comment: comment) == pair.publicKey)
        #expect(SSHKeys.fingerprint(openSSHPublicKey: pair.publicKey).hasPrefix("SHA256:"))
    }
}

/// Live test against a real server. Runs only when DECKHAND_TEST_HOST is set, e.g.
/// DECKHAND_TEST_HOST=example.com DECKHAND_TEST_PORT=22 DECKHAND_TEST_USER=me DECKHAND_TEST_KEY=~/.ssh/id_ed25519 swift test
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_TEST_HOST"] != nil))
struct LiveSSHTests {
    func connection() async throws -> SSHConnection {
        let env = ProcessInfo.processInfo.environment
        let keyPath = (env["DECKHAND_TEST_KEY"]! as NSString).expandingTildeInPath
        let key = try String(contentsOfFile: keyPath, encoding: .utf8)
        let conn = SSHConnection(
            endpoint: SSHEndpoint(host: env["DECKHAND_TEST_HOST"]!, port: Int(env["DECKHAND_TEST_PORT"] ?? "22")!, username: env["DECKHAND_TEST_USER"]!),
            credential: .privateKey(key, passphrase: nil))
        try await conn.connect(pinnedHostKey: nil, trustNewHostKey: { _, _ in true })
        return conn
    }

    @Test func runsCommandsAndReportsExitCodes() async throws {
        let conn = try await connection()
        let ok = try await conn.run("echo hi; echo err >&2", timeout: .seconds(20))
        #expect(ok.stdout == "hi\n")
        #expect(ok.stderr.contains("err"))
        #expect(ok.exitCode == 0)
        let bad = try await conn.run("exit 7", timeout: .seconds(20))
        #expect(bad.exitCode == 7)
        let slow = try await conn.run("sleep 5", timeout: .seconds(1))
        #expect(slow.exitCode == 124)
        #expect(await conn.hostKey != nil)
        await conn.disconnect()
    }

    @Test func serverToolsWorkOverSSH() async throws {
        let conn = try await connection()
        let dir = "/tmp/deckhand-test-\(UUID().uuidString.prefix(8))"
        let tools = ServerTools.all(workingDirectory: dir)
        func tool(_ n: String) -> any AgentTool { tools.first { $0.spec.name == n }! }
        _ = try await tool("write_file").execute(["path": "a/b.txt", "content": "one\n'two' $x\n"], shell: conn)
        let read = try await tool("read_file").execute(["path": "a/b.txt"], shell: conn)
        #expect(read.contains("'two' $x"))
        _ = try await tool("edit_file").execute(["path": "a/b.txt", "old_string": "one", "new_string": "uno"], shell: conn)
        let found = try await tool("search").execute(["pattern": "uno"], shell: conn)
        #expect(found.contains("b.txt"))
        _ = try await conn.run("rm -rf \(dir)", timeout: .seconds(10))
        await conn.disconnect()
    }

    @Test func terminalEchoes() async throws {
        let conn = try await connection()
        let term = try await conn.openTerminal(cols: 80, rows: 24)
        term.send("echo deckhand-$((40+2))\n")
        var seen = ""
        for await chunk in term.output {
            seen += String(decoding: chunk, as: UTF8.self)
            if seen.contains("deckhand-42") { break }
        }
        #expect(seen.contains("deckhand-42"))
        term.close()
        await conn.disconnect()
    }
}

/// Runs a real Codex turn on the server. Opt-in (uses the user's subscription): DECKHAND_TEST_CLI=1 plus the SSH vars.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_TEST_CLI"] != nil))
struct LiveServerCLITests {
    @Test func codexTurnStreamsEvents() async throws {
        let conn = try await LiveSSHTests().connection()
        var session: String?
        var sawCommand = false
        var finished = false
        for try await e in ServerCLIRun.run(
            .codex, shell: conn, prompt: "Run `echo deckhand-ok` and reply with its output only.",
            workingDirectory: "/tmp", sessionID: nil, access: .readOnly)
        {
            switch e {
            case .sessionStarted(let id): session = id
            case .toolFinished(let call, let r): if call.name == "run_command", r.content.contains("deckhand-ok") { sawCommand = true }
            case .finished(.endTurn): finished = true
            default: break
            }
        }
        #expect(session != nil)
        #expect(sawCommand)
        #expect(finished)
        await conn.disconnect()
    }
}

extension LiveSSHTests {
    @Test func inventoryProbe() async throws {
        let conn = try await connection()
        let r = try await conn.run(ServerInventory.probeCommand, timeout: .seconds(60))
        let inv = ServerInventory.parse(r.stdout)
        #expect(inv.codex.isInstalled)
        #expect(inv.claudeCode.isInstalled)
        #expect(inv.os?.contains("Ubuntu") == true)
        await conn.disconnect()
    }
}

extension LiveSSHTests {
    @Test func stdioMCPServerOverSSH() async throws {
        let conn = try await connection()
        let script = try String(contentsOfFile: #filePath.replacingOccurrences(of: "DeckhandSSHTests/SSHTests.swift", with: "DeckhandCoreTests/Fixtures/fake_mcp_server.py"), encoding: .utf8)
        let remote = "/tmp/deckhand-fake-mcp-\(UUID().uuidString.prefix(6)).py"
        try await ServerTools.writeFile(remote, content: script, shell: conn)
        let client = MCPClient(name: "fake", transport: StdioMCPTransport(channel: try await conn.openChannel("python3 -u \(remote)")))
        let tools = try await client.tools()
        #expect(tools.count == 2)
        let r = try await client.call("echo", arguments: ["text": "over ssh"])
        #expect(r.text == "echo: over ssh")
        await client.close()
        _ = try await conn.run("rm -f \(remote)", timeout: .seconds(10))
        await conn.disconnect()
    }
}

/// Public HTTP MCP server, opt-in: DECKHAND_TEST_HTTP_MCP=1
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_TEST_HTTP_MCP"] != nil))
struct LiveHTTPMCPTests {
    @Test func deepWiki() async throws {
        let client = MCPClient(name: "deepwiki", transport: HTTPMCPTransport(url: URL(string: "https://mcp.deepwiki.com/mcp")!))
        let tools = try await client.tools()
        #expect(!tools.isEmpty)
        print("deepwiki tools:", tools.map(\.name))
        await client.close()
    }
}

extension LiveSSHTests {
    @Test func connectionSyncOnServer() async throws {
        let conn = try await connection()
        let wiki = MCPConnection(name: "deepwiki-test", transport: .http(url: "https://mcp.deepwiki.com/mcp"))
        let add = try await conn.run(ConnectionSync.script([(wiki, nil)]), timeout: .seconds(180))
        #expect(ConnectionSync.results(add.stdout)["deepwiki-test"] == [.claudeCode: true, .codex: true])
        let listed = try await conn.run("claude mcp list 2>&1; codex mcp list 2>&1", timeout: .seconds(120))
        #expect(listed.stdout.components(separatedBy: "deepwiki-test").count >= 3)
        _ = try await conn.run(ConnectionSync.script([]), timeout: .seconds(180))
        let after = try await conn.run("claude mcp list 2>&1; codex mcp list 2>&1", timeout: .seconds(120))
        #expect(!after.stdout.contains("deepwiki-test"))
        await conn.disconnect()
    }
}

extension LiveSSHTests {
    @Test func serverStatsLive() async throws {
        let conn = try await connection()
        let r = try await conn.run(ServerStats.probeCommand, timeout: .seconds(20))
        let s = try #require(ServerStats.parse(r.stdout))
        #expect(s.cores > 0)
        #expect(s.memTotalKB > 0)
        #expect(!s.disks.isEmpty)
        await conn.disconnect()
    }
}

extension LiveSSHTests {
    @Test func servicesLive() async throws {
        let conn = try await connection()
        let list = Services.parse(try await conn.run(Services.listCommand, timeout: .seconds(20)).stdout)
        #expect(!list.isEmpty)
        let status = try await conn.run(Services.statusCommand(list[0].name), timeout: .seconds(20))
        #expect(status.stdout.contains(list[0].name))
        let logs = try await conn.run(Services.logsCommand(list[0].name, lines: 5), timeout: .seconds(20))
        #expect(!logs.stdout.isEmpty)
        await conn.disconnect()
    }
}

extension LiveSSHTests {
    @Test func logsLive() async throws {
        let conn = try await connection()
        let sources = Logs.parseSources(try await conn.run(Logs.discoverCommand, timeout: .seconds(30)).stdout)
        #expect(!sources.isEmpty)
        if let file = sources.first(where: { if case .file = $0 { true } else { false } }) {
            let r = try await conn.run(Logs.readCommand(file, lines: 5), timeout: .seconds(20))
            #expect(r.exitCode == 0)
        }
        var got = false
        for try await _ in conn.streamLines(Logs.followCommand(.journal(unit: nil), seconds: 2)) { got = true; break }
        _ = got
        await conn.disconnect()
    }
}

extension LiveSSHTests {
    /// Read-only: lists containers and compose projects on the test server.
    @Test func dockerOverviewLive() async throws {
        let conn = try await connection()
        let o = Docker.parseOverview(try await conn.run(Docker.overviewCommand, timeout: .seconds(60)).stdout)
        #expect(o.installed)
        if !o.permissionDenied { #expect(!o.containers.isEmpty) }
        await conn.disconnect()
    }
}

extension LiveSSHTests {
    /// A detached run survives a dropped connection: read a bit, disconnect, reconnect and continue from the checkpoint.
    @Test func detachedRunSurvivesDisconnect() async throws {
        let run = DetachedRun()
        var conn = try await connection()
        _ = try await conn.run(run.startCommand("for i in 1 2 3 4 5; do echo line$i; sleep 1; done"), timeout: .seconds(20))
        var seen: [String] = []
        for try await line in conn.streamLines(run.readCommand(fromLine: 1)) {
            seen.append(line)
            if seen.count == 2 { break }
        }
        await conn.disconnect()               // the phone loses its connection
        try await Task.sleep(for: .seconds(2))
        conn = try await connection()         // …and comes back
        for try await line in conn.streamLines(run.readCommand(fromLine: seen.count + 1)) { seen.append(line) }
        #expect(seen == ["line1", "line2", "line3", "line4", "line5", "@@exit 0"])
        _ = try await conn.run("rm -f ~/.deckhand/runs/\(run.id).*", timeout: .seconds(10))
        await conn.disconnect()
    }
}

extension LiveSSHTests {
    /// A run that hits a usage limit waits on the server until the reset time it reads from the message, then resumes.
    @Test func limitAwareRunResumesAfterReset() async throws {
        let conn = try await connection()
        let dir = "/tmp/dh-limit-\(UUID().uuidString.prefix(6))"
        // A fake `claude`: the first turn hits a limit that resets at one to two minutes (UTC), --resume finishes.
        let fake = #"""
        #!/bin/bash
        case " $* " in
          *" --resume "*) echo '{"type":"system","subtype":"init","session_id":"s-1"}'; echo '{"type":"result","is_error":false,"result":"ok","usage":{}}' ;;
          *) echo '{"type":"system","subtype":"init","session_id":"s-1"}'
             echo "{\"type\":\"result\",\"is_error\":true,\"result\":\"You've hit your limit · resets $(TZ=UTC date -d '+2 min' +%-I:%M%P) (Etc/UTC)\",\"usage\":{}}"
             exit 1 ;;
        esac
        """#
        _ = try await conn.run("mkdir -p \(dir)/bin && printf '%s\\n' \(ShellQuote.quote(fake)) > \(dir)/bin/claude && chmod +x \(dir)/bin/claude", timeout: .seconds(10))
        let run = DetachedRun()
        let command = "export PATH=\(dir)/bin:$PATH DH_SLACK=0; " + LimitAwareRun.command(
            .claudeCode, prompt: "fix it", workingDirectory: "~", sessionID: nil, access: .edit, run: run)
        _ = try await conn.run(run.startCommand(command, meta: .init(title: "Limit test", engine: "Claude Code", directory: "~")), timeout: .seconds(20))
        try await Task.sleep(for: .seconds(3))
        let during = DetachedRun.parseList(try await conn.run(DetachedRun.listCommand, timeout: .seconds(10)).stdout).first { $0.id == run.id }
        guard case .waiting(let until)? = during?.status else { Issue.record("not waiting: \(String(describing: during))"); return }
        #expect(until.timeIntervalSinceNow < 135)
        var lines: [String] = []
        for try await line in conn.streamLines(run.readCommand(fromLine: 1)) { lines.append(line) }
        #expect(lines.contains { $0.contains("deckhand.waiting") })
        #expect(lines.contains { $0.contains("deckhand.resumed") })
        #expect(lines.last == "@@exit 0")
        _ = try await conn.run(run.deleteCommand + "; rm -rf \(dir)", timeout: .seconds(10))
        await conn.disconnect()
    }
}
