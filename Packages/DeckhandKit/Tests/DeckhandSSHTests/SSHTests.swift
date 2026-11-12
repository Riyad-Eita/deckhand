import Crypto
@testable import DeckhandCore
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

    /// The server's Codex lists its models; a turn with a chosen model and effort runs; Claude Code accepts the flags.
    @Test func modelAndEffortReachTheCLIs() async throws {
        let conn = try await LiveSSHTests().connection()
        let models = CLIModels.parseCodex(try await conn.run(CLIModels.codexCommand, timeout: .seconds(60)).stdout)
        #expect(!models.isEmpty)
        let pick = try #require(models.first)
        let effort = pick.efforts.first ?? "low"
        let run = DetachedRun()
        var text = ""
        var finished = false
        for try await e in ServerCLIRun.runDetached(
            .codex, shell: conn, prompt: "Reply with just: model-ok", workingDirectory: "/tmp", sessionID: nil,
            access: .readOnly, options: CLIOptions(model: pick.id, effort: effort), run: run)
        {
            if case .message(let m) = e { text += m.text }
            if case .finished(.endTurn) = e { finished = true }
        }
        #expect(finished && text.contains("model-ok"), "\(text)")
        _ = try await conn.run("rm -f ~/.deckhand/runs/\(run.id).*", timeout: .seconds(10))
        // Claude Code: unknown flags would fail with "unknown option" before any login check.
        let claude = try await conn.run(
            "PATH=$HOME/.local/bin:$PATH timeout 20 claude -p hi --model sonnet --effort low --output-format stream-json --verbose </dev/null 2>&1 | head -c 2000",
            timeout: .seconds(40))
        #expect(!claude.stdout.lowercased().contains("unknown option"), "\(claude.stdout)")
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

/// Live root tests against a disposable server where the user needs a sudo password, e.g.
/// DECKHAND_SUDO_HOST=example.com DECKHAND_SUDO_PORT=22 DECKHAND_SUDO_USER=me DECKHAND_SUDO_PASSWORD=… swift test
/// (the password is both the login and the sudo password). Changes only /etc/deckhand-test.conf.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_SUDO_HOST"] != nil), .serialized)
struct LiveSudoTests {
    let env = ProcessInfo.processInfo.environment

    func connection() async throws -> SSHConnection {
        let conn = SSHConnection(
            endpoint: SSHEndpoint(host: env["DECKHAND_SUDO_HOST"]!, port: Int(env["DECKHAND_SUDO_PORT"] ?? "22")!, username: env["DECKHAND_SUDO_USER"]!),
            credential: .password(env["DECKHAND_SUDO_PASSWORD"]!))
        try await conn.connect(pinnedHostKey: nil, trustNewHostKey: { _, _ in true })
        return conn
    }

    func root(_ script: String, _ conn: SSHConnection, password: String?) async throws -> [RootLine] {
        var out: [RootLine] = []
        for try await l in Sudo.run(script, on: conn, access: .password, password: password) { out.append(l) }
        return out
    }

    @Test func changeWithSudoPasswordDiffAndRollback() async throws {
        let conn = try await connection()
        let pw = env["DECKHAND_SUDO_PASSWORD"]!
        #expect(Sudo.parseProbe(try await conn.run(Sudo.probeCommand, timeout: .seconds(15)).stdout) == .password)
        let who = try await root("id -u", conn, password: pw); #expect(who.last == .exit(0) && who.contains(.output("0")), "\(who)")
        await #expect(throws: SudoError.wrongPassword) { _ = try await root("id -u", conn, password: "wrong-" + pw) }

        let file = "/etc/deckhand-test.conf"
        let change = ConfigChange(title: "Live test", files: [file], apply: "echo 'MaxAuthTries 3' > \(file)", validate: "true")
        let id = ConfigChange.makeID(title: change.title)
        let applied = try await root(change.script(id: id), conn, password: pw)
        #expect(applied.contains(.output("@@done")))
        #expect(try await conn.run("cat \(file)", timeout: .seconds(10)).stdout == "MaxAuthTries 3\n")
        // The history is readable without root, the backed-up files are not.
        let history = ConfigChange.parseList(try await conn.run(ConfigChange.listCommand(), timeout: .seconds(10)).stdout)
        #expect(history.first { $0.id == id }?.status == .applied)
        #expect(try await conn.run("ls \(ConfigChange.defaultRoot)/\(id)/files", timeout: .seconds(10)).exitCode != 0)
        let diff = try await root(ConfigChange.diffScript(id: id), conn, password: pw)
        #expect(diff.contains(.output("+MaxAuthTries 3")))
        let back = try await root(ConfigChange.rollbackScript(id: id), conn, password: pw)
        #expect(back.contains(.output("@@done")))
        #expect(try await conn.run("test -e \(file)", timeout: .seconds(10)).exitCode != 0)
        _ = try await root("rm -rf \(ConfigChange.defaultRoot)/\(id)", conn, password: pw)
        await conn.disconnect()
    }
}

/// Moves SSH to another port on a disposable systemd server (Ubuntu 24.04 with ssh.socket and ufw), e.g.
/// DECKHAND_PORT_HOST=example.com DECKHAND_PORT_OLD=22 DECKHAND_PORT_NEW=40022 DECKHAND_PORT_USER=me DECKHAND_PORT_PASSWORD=… swift test
/// DECKHAND_PORT_OLD is how the old port is reached from here (it may be mapped); the server itself uses 22.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_PORT_HOST"] != nil), .serialized)
struct LivePortTests {
    let env = ProcessInfo.processInfo.environment
    var newPort: Int { Int(env["DECKHAND_PORT_NEW"]!)! }

    func connect(_ port: Int) async throws -> SSHConnection {
        let conn = SSHConnection(
            endpoint: SSHEndpoint(host: env["DECKHAND_PORT_HOST"]!, port: port, username: env["DECKHAND_PORT_USER"]!),
            credential: .password(env["DECKHAND_PORT_PASSWORD"]!))
        try await conn.connect(pinnedHostKey: nil, trustNewHostKey: { _, _ in true })
        return conn
    }
    var oldPort: Int { Int(env["DECKHAND_PORT_OLD"]!)! }

    func root(_ script: String, _ conn: SSHConnection) async throws -> [String] {
        var out: [String] = []
        for try await l in Sudo.run(script, on: conn, access: .password, password: env["DECKHAND_PORT_PASSWORD"]!) {
            if case .output(let s) = l { out.append(s) }
        }
        return out
    }

    func inspect(_ conn: SSHConnection) async throws -> SSHPort.Inspection {
        SSHPort.parse(try await root(SSHPort.inspectScript, conn).joined(separator: "\n"))
    }

    @Test func movesThePortInTwoGuardedSteps() async throws {
        var conn = try await connect(oldPort)
        let before = try await inspect(conn)
        #expect(before.ports == [22])
        #expect(before.socketActivated)
        #expect(before.firewall == .ufw)
        #expect(before.firewallSSHRules == ["22/tcp:allow"])

        // Step 1: the new port next to 22, then prove a login on it and confirm.
        let add = SSHPort.addPort(newPort, inspection: before)
        let addID = ConfigChange.makeID(title: add.title)
        let r1 = try await root(add.script(id: addID), conn)
        #expect(r1.contains("@@done"), "\(r1)")
        let onNew = try await connect(newPort)
        #expect(try await onNew.run("echo ok", timeout: .seconds(10)).stdout == "ok\n")
        #expect(try await root(ConfigChange.confirmScript(id: addID), onNew).contains("@@done"))
        await conn.disconnect()
        conn = onNew

        // Step 2: close 22 over the new connection.
        let mid = try await inspect(conn)
        #expect(Set(mid.ports) == [22, newPort])
        let close = SSHPort.closeOldPorts(keep: newPort, inspection: mid)
        let closeID = ConfigChange.makeID(title: close.title, date: Date().addingTimeInterval(1))
        let r2 = try await root(close.script(id: closeID), conn)
        #expect(r2.contains("@@done"), "\(r2)")
        let again = try await connect(newPort)
        #expect(try await root(ConfigChange.confirmScript(id: closeID), again).contains("@@done"))
        await #expect(throws: (any Error).self) { _ = try await connect(oldPort).run("true", timeout: .seconds(5)) }
        let after = try await inspect(again)
        #expect(after.ports == [newPort])
        #expect(!after.firewallSSHRules.contains("22/tcp:allow"))

        // Undo both (newest first) so the server is as before.
        #expect(try await root(ConfigChange.rollbackScript(id: closeID), again).contains("@@done"))
        #expect(try await root(ConfigChange.rollbackScript(id: addID), again).contains("@@done"))
        await again.disconnect()
        let back = try await connect(oldPort)
        #expect(try await inspect(back).ports == [22])
        await back.disconnect()
        await conn.disconnect()
    }

    @Test func unconfirmedPortChangeRollsBackByItself() async throws {
        let conn = try await connect(oldPort)
        let add = SSHPort.addPort(newPort, inspection: try await inspect(conn), guardSeconds: 15)
        let r = try await root(add.script(id: ConfigChange.makeID(title: add.title + " guard")), conn)
        #expect(r.contains("@@guard 15"))
        #expect(try await inspect(conn).ports.contains(newPort))
        try await Task.sleep(for: .seconds(25))
        #expect(try await inspect(conn).ports == [22])
        await conn.disconnect()
    }
}

extension LivePortTests {
    /// Security check-up on the disposable systemd server: audit, apply fixes (fail2ban, automatic updates,
    /// guarded SSH hardening with a fresh login), see the score go up, then roll everything back.
    @Test func auditAndFixes() async throws {
        let conn = try await connect(oldPort)
        let ctx = SecurityAudit.Context(loginUser: env["DECKHAND_PORT_USER"]!, usesKey: false)
        func audit() async throws -> [SecurityAudit.Check] {
            SecurityAudit.checks(SecurityAudit.parse(try await root(SecurityAudit.script, conn).joined(separator: "\n")), context: ctx)
        }
        let before = try await audit()
        let level = { (checks: [SecurityAudit.Check], id: String) in checks.first { $0.id == id }?.level }
        #expect(level(before, "ssh.password") == .bad)
        #expect(level(before, "firewall") == .good)
        #expect(level(before, "fail2ban") == .warn)

        var ids: [String] = []
        for id in ["fail2ban", "autoupdates", "ssh.extras"] {
            guard case .change(let change, let guarded)? = before.first(where: { $0.id == id })?.fix else { Issue.record("no fix for \(id)"); continue }
            let cid = ConfigChange.makeID(title: change.title, date: Date().addingTimeInterval(Double(ids.count)))
            let out = try await root(change.script(id: cid), conn)
            #expect(out.contains("@@done"), "\(id): \(out.suffix(8))")
            if guarded {
                let fresh = try await connect(oldPort)   // still able to log in
                #expect(try await root(ConfigChange.confirmScript(id: cid), fresh).contains("@@done"))
                await fresh.disconnect()
            }
            ids.append(cid)
        }
        let after = try await audit()
        #expect(level(after, "fail2ban") == .good)
        #expect(level(after, "autoupdates") == .good)
        #expect(level(after, "ssh.extras") == .good)
        #expect(SecurityAudit.score(after) > SecurityAudit.score(before))

        for cid in ids.reversed() { #expect(try await root(ConfigChange.rollbackScript(id: cid), conn).contains("@@done")) }
        let undone = try await audit()
        #expect(level(undone, "ssh.extras") == .warn)
        #expect(level(undone, "autoupdates") == .warn)
        _ = try await root("rm -rf \(ConfigChange.defaultRoot)/*", conn)
        await conn.disconnect()
    }
}

/// Provisions a disposable fresh server (root login with a password), e.g.
/// DECKHAND_PROV_HOST=example.com DECKHAND_PROV_PORT=22 DECKHAND_PROV_ROOT_PASSWORD=… swift test
/// Leaves the server hardened — recreate it before running again.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_PROV_HOST"] != nil), .serialized)
struct LiveProvisionTests {
    let env = ProcessInfo.processInfo.environment

    func connect(_ user: String, _ credential: SSHCredential) async throws -> SSHConnection {
        let conn = SSHConnection(
            endpoint: SSHEndpoint(host: env["DECKHAND_PROV_HOST"]!, port: Int(env["DECKHAND_PROV_PORT"] ?? "22")!, username: user),
            credential: credential)
        try await conn.connect(pinnedHostKey: nil, trustNewHostKey: { _, _ in true })
        return conn
    }

    func root(_ script: String, _ conn: SSHConnection, access: SudoAccess, password: String? = nil, input: [String] = []) async throws -> [String] {
        var out: [String] = []
        for try await l in Sudo.run(script, on: conn, access: access, password: password, input: input) {
            if case .output(let s) = l { out.append(s) }
        }
        return out
    }

    @Test func freshServerEndsUpHardened() async throws {
        let rootPW = env["DECKHAND_PROV_ROOT_PASSWORD"]!
        let asRoot = try await connect("root", .password(rootPW))
        #expect(Sudo.parseProbe(try await asRoot.run(Sudo.probeCommand, timeout: .seconds(10)).stdout) == .root)
        let facts = SecurityAudit.parse(try await root(Provisioning.inspectScript, asRoot, access: .root).joined(separator: "\n"))
        #expect(facts["pm"] == "apt")
        #expect(facts["firewall"] == "none")

        // 1. Admin user with sudo and a fresh key; the sudo password only travels over stdin.
        let pair = SSHKeys.generateEd25519(comment: "deckhand-test")
        let sudoPW = Provisioning.generatePassword()
        let created = try await root(Provisioning.createAdminScript(username: "deploy", publicKey: pair.publicKey), asRoot, access: .root, input: [sudoPW])
        #expect(created.contains("@@done"), "\(created)")

        // 2. Key login as the new user, sudo with the new password.
        let asAdmin = try await connect("deploy", .privateKey(pair.privateKey, passphrase: nil))
        #expect(Sudo.parseProbe(try await asAdmin.run(Sudo.probeCommand, timeout: .seconds(10)).stdout) == .password)
        #expect(try await root("id -u", asAdmin, access: .password, password: sudoPW) == ["0"])
        await asRoot.disconnect()

        // 3. Root and password logins off (guarded), proven with a fresh key login before confirming.
        let ssh = Hardening.ssh(context: .init(loginUser: "deploy", usesKey: true), includeEnabled: facts["ssh.include"] == "yes")
        let sshID = ConfigChange.makeID(title: ssh.title)
        #expect(try await root(ssh.script(id: sshID), asAdmin, access: .password, password: sudoPW).contains("@@done"))
        let fresh = try await connect("deploy", .privateKey(pair.privateKey, passphrase: nil))
        #expect(try await root(ConfigChange.confirmScript(id: sshID), fresh, access: .password, password: sudoPW).contains("@@done"))
        await #expect(throws: (any Error).self) { _ = try await connect("root", .password(rootPW)) }

        // 4. Firewall (guarded), SSH stays reachable.
        let ufw = Hardening.ufw(open: [22])
        let fwID = ConfigChange.makeID(title: ufw.title, date: Date().addingTimeInterval(1))
        #expect(try await root(ufw.script(id: fwID), fresh, access: .password, password: sudoPW).contains("@@done"))
        let again = try await connect("deploy", .privateKey(pair.privateKey, passphrase: nil))
        #expect(try await root(ConfigChange.confirmScript(id: fwID), again, access: .password, password: sudoPW).contains("@@done"))

        let audit = SecurityAudit.checks(
            SecurityAudit.parse(try await root(SecurityAudit.script, again, access: .password, password: sudoPW).joined(separator: "\n")),
            context: .init(loginUser: "deploy", usesKey: true))
        for id in ["ssh.password", "ssh.root", "firewall"] { #expect(audit.first { $0.id == id }?.level == .good, "\(id)") }
        await again.disconnect(); await fresh.disconnect(); await asAdmin.disconnect()
    }
}

extension LiveSSHTests {
    /// A web server that only listens on the server's localhost opens through a local forwarded port.
    @Test func forwardsAPortToTheServersLocalhost() async throws {
        let conn = try await connection()
        let port = Int.random(in: 41000...48000)
        let dir = "/tmp/dh-fwd-\(port)"
        _ = try await conn.run("mkdir -p \(dir) && echo 'hello through ssh' > \(dir)/index.html && { nohup python3 -m http.server \(port) --bind 127.0.0.1 --directory \(dir) </dev/null >/dev/null 2>&1 & } ; sleep 1", timeout: .seconds(15))
        let forward = try await conn.forward(remotePort: port)
        defer { forward.stop() }
        for path in ["index.html", "index.html"] {   // twice: every request gets its own SSH channel
            let (data, response) = try await URLSession.shared.data(from: forward.url.appending(path: path))
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self) == "hello through ssh\n")
        }
        _ = try await conn.run("pkill -f 'http.server \(port) --bind 127.0.0.1'; rm -rf \(dir)", timeout: .seconds(10))
        await conn.disconnect()
    }
}

extension LiveSSHTests {
    /// A closed port gets a clear error instead of a tunnel to nowhere.
    @Test func forwardToAClosedPortSaysSo() async throws {
        let conn = try await connection()
        do {
            _ = try await conn.forward(remotePort: 1)
            Issue.record("expected an error")
        } catch let failure as PortForward.Failure {
            #expect(failure == .nothingListening(1), "\(failure)")
        }
        await conn.disconnect()
    }
}

extension LiveSSHTests {
    /// Uploads arrive byte for byte and never overwrite an existing file.
    @Test func uploadsWithoutOverwriting() async throws {
        let conn = try await connection()
        let dir = "/tmp/dh-up-\(UUID().uuidString.prefix(8))"
        let data = Data((0..<200_000).map { _ in UInt8.random(in: 0...255) })
        let progress = ProgressLog()
        let first = try await conn.upload(data, named: "photo one.jpg", into: dir) { progress.add($0) }
        // The second one without SFTP: base64 over exec.
        let second = try await conn.upload(data, named: "photo one.jpg", into: dir, useSFTP: false) { _ in }
        #expect(first == "\(dir)/photo one.jpg")
        #expect(second == "\(dir)/photo one-2.jpg")
        let sums = try await conn.run("sha256sum \(ShellQuote.quote(first)) \(ShellQuote.quote(second)) | cut -d' ' -f1", timeout: .seconds(10)).stdout
        let local = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(sums == "\(local)\n\(local)\n")
        #expect(progress.values.last == 1 && progress.values.count > 3)
        _ = try await conn.run("rm -rf \(ShellQuote.quote(dir))", timeout: .seconds(10))
        await conn.disconnect()
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Double] = []
    func add(_ v: Double) { lock.withLock { all.append(v) } }
    var values: [Double] { lock.withLock { all } }
}

extension LiveSSHTests {
    /// File browser on a real server: awkward names, links, hidden files, rename, conflicts, new folder, delete.
    /// Also lists the same folder with the POSIX fallback inside a BusyBox container when Docker is available.
    @Test func remoteFilesLive() async throws {
        let conn = try await connection()
        let dir = "/tmp/deckhand-files-\(UUID().uuidString.prefix(8))"
        _ = try await conn.run(
            "mkdir -p \(dir)/sub && cd \(dir) && printf hello > 'a b.txt' && printf x > .hidden && "
                + "printf y > \"$(printf 'new\\nline')\" && ln -s sub link && ln -s nowhere dead && printf z > \"it's\"",
            timeout: .seconds(20))
        do { try await checkRemoteFiles(conn, dir) } catch { Issue.record(error) }
        _ = try? await conn.run("rm -rf \(dir)", timeout: .seconds(20))
        await conn.disconnect()
    }

    private func checkRemoteFiles(_ conn: SSHConnection, _ dir: String) async throws {
        let folder = try await RemoteFiles.list(dir, shell: conn)
        #expect(folder.path == dir && folder.writable)
        let names = Set(folder.entries.map(\.name))
        #expect(names == ["sub", "a b.txt", ".hidden", "new\nline", "link", "dead", "it's"])
        #expect(folder.entries.first { $0.name == "link" }?.opensAsFolder == true)
        #expect(folder.entries.first { $0.name == "dead" }?.opensAsFolder == false)
        #expect(folder.entries.first { $0.name == "a b.txt" }?.size == 5)

        try await RemoteFiles.rename(in: dir, from: "a b.txt", to: "c d.txt", shell: conn)
        await #expect(throws: ToolError.self) { try await RemoteFiles.rename(in: dir, from: "c d.txt", to: "it's", shell: conn) }
        try await RemoteFiles.makeFolder(in: dir, name: "new folder", shell: conn)
        await #expect(throws: ToolError.self) { try await RemoteFiles.makeFolder(in: dir, name: "new folder", shell: conn) }
        try await RemoteFiles.delete("\(dir)/sub", shell: conn)
        try await RemoteFiles.delete("\(dir)/new\nline", shell: conn)
        let after = Set(try await RemoteFiles.list(dir, shell: conn).entries.map(\.name))
        #expect(after == ["c d.txt", ".hidden", "link", "dead", "it's", "new folder"])
        await #expect(throws: ToolError.self) { try await RemoteFiles.delete("/tmp", shell: conn) }
        let home = try await conn.run("cd ~ && pwd -P", timeout: .seconds(10)).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if home.split(separator: "/").count >= 2 {
            await #expect(throws: ToolError.self) { try await RemoteFiles.delete(home, shell: conn) }
        }

        // POSIX fallback (BusyBox: no find -printf).
        let docker = try await conn.run("docker info >/dev/null 2>&1 && echo yes", timeout: .seconds(20))
        if docker.stdout.contains("yes") {
            let r = try await conn.run(
                "docker run --rm -v \(dir):/d:ro busybox sh -c \(ShellQuote.quote(RemoteFiles.listCommand("/d")))",
                timeout: .seconds(120))
            let busy = try #require(RemoteFiles.parse(r.stdout), "\(r.stderr)")
            #expect(Set(busy.entries.map(\.name)) == after)
            #expect(busy.entries.first { $0.name == "link" }?.kind == .link)
            #expect(busy.entries.first { $0.name == "c d.txt" }?.size == 5)
            #expect(busy.entries.first { $0.name == "new folder" }?.opensAsFolder == true)
        }
    }
}

extension LiveSSHTests {
    /// Process list on a real server: finds a process we start, measures a busy one, ends both; a root process can't be killed.
    @Test func processesLive() async throws {
        let conn = try await connection()
        let tag = "deckhand-proc-\(UUID().uuidString.prefix(6))"
        _ = try await conn.run("nohup bash -c 'exec -a \(tag) sleep 300' >/dev/null 2>&1 </dev/null & "
            + "nohup sh -c 'while :; do :; done # \(tag)-busy' >/dev/null 2>&1 </dev/null &", timeout: .seconds(10))
        do {
            let r = try await conn.run(Processes.command, timeout: .seconds(30))
            let snap = try #require(Processes.parse(r.stdout), "\(r.stderr)")
            #expect(snap.cores >= 1 && snap.memTotalKB > 0)
            let sleeper = try #require(snap.processes.first { $0.command.contains(tag) && !$0.command.contains("busy") })
            #expect(sleeper.user == snap.me)
            let busy = try #require(snap.processes.first { $0.command.contains("\(tag)-busy") && $0.name == "sh" })
            #expect(busy.cpu > 50, "busy loop at \(busy.cpu) %")
            #expect(Processes.sorted(snap.processes, by: .cpu).prefix(5).contains { $0.pid == busy.pid })

            for pid in [sleeper.pid, busy.pid] {
                let k = try await conn.run(Processes.killCommand(pid: pid)!, timeout: .seconds(20))
                #expect(k.exitCode == 0, "\(k.stderr)")
            }
            let after = try await conn.run("ps -p \(sleeper.pid),\(busy.pid) -o pid= || true", timeout: .seconds(10))
            #expect(after.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if snap.me != "root", let rootProc = snap.processes.first(where: { $0.user == "root" && !$0.isKernelThread && $0.pid > 1 }) {
                let denied = try await conn.run(Processes.killCommand(pid: rootProc.pid, force: true)!, timeout: .seconds(10))
                #expect(denied.exitCode != 0)
                #expect(Processes.killMessage(denied.stderr) == "This process belongs to another user.")
            }
        } catch { Issue.record(error) }
        _ = try? await conn.run("pkill -f '[d]eckhand-proc-'", timeout: .seconds(10))
        await conn.disconnect()
    }
}

extension LiveSSHTests {
    /// Package updates: the read-only status on the test server, then refresh + install one update as root inside a
    /// throwaway Ubuntu container (when Docker and DECKHAND_TEST_UBUNTU_IMAGE are available). Removes the container.
    @Test func packageUpdatesLive() async throws {
        let conn = try await connection()
        do {
            let status = PackageUpdates.parse(try await conn.run(PackageUpdates.statusCommand, timeout: .seconds(120)).stdout)
            #expect(status.manager != nil)
            #expect(!status.runningKernel.isEmpty)
            if status.manager == "apt" {
                let count = try await conn.run("apt list --upgradable 2>/dev/null | grep -c 'upgradable from' || true", timeout: .seconds(60))
                #expect(status.updates.count == Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1)
            }

            if let image = ProcessInfo.processInfo.environment["DECKHAND_TEST_UBUNTU_IMAGE"] {
                let box = "dh-updates-\(UUID().uuidString.prefix(6).lowercased())"
                _ = try await conn.run("docker run -d --rm --name \(box) --entrypoint sleep \(ShellQuote.quote(image)) 900", timeout: .seconds(60))
                func inBox(_ script: String) async throws -> CommandResult {
                    try await conn.run("docker exec \(box) bash -c \(ShellQuote.quote(script))", timeout: .seconds(600))
                }
                let refresh = try await inBox(PackageUpdates.refreshScript("apt"))
                #expect(refresh.stdout.contains("@@done"), "\(refresh.stderr)")
                let before = PackageUpdates.parse(try await inBox(PackageUpdates.statusCommand).stdout)
                #expect(before.manager == "apt" && before.listAgeDays == 0)
                // The smallest-looking candidate: libraries and tools, not the kernel.
                if let pick = before.updates.first(where: { !$0.name.hasPrefix("linux") }) {
                    let install = try await inBox(PackageUpdates.installScript("apt", packages: [pick.name]))
                    #expect(install.exitCode == 0 && install.stdout.contains("@@done"), "\(install.stdout.suffix(500)) \(install.stderr)")
                    let after = PackageUpdates.parse(try await inBox(PackageUpdates.statusCommand).stdout)
                    #expect(!after.updates.contains { $0.name == pick.name }, "\(pick.name) still listed")
                }
                _ = try? await conn.run("docker rm -f \(box)", timeout: .seconds(60))
            }
        } catch { Issue.record(error) }
        await conn.disconnect()
    }
}

extension LiveSSHTests {
    /// Real connection failures read as plain sentences and fall into the right kind of problem.
    @Test func connectionErrorsInPlainWords() async throws {
        let env = ProcessInfo.processInfo.environment
        let host = env["DECKHAND_TEST_HOST"]!, port = Int(env["DECKHAND_TEST_PORT"] ?? "22")!
        func fail(_ h: String, _ p: Int, _ user: String, _ cred: SSHCredential) async -> String {
            let c = SSHConnection(endpoint: SSHEndpoint(host: h, port: p, username: user), credential: cred)
            do { try await c.connect(pinnedHostKey: nil, trustNewHostKey: { _, _ in true }); return "connected" }
            catch { return error.localizedDescription }
        }
        let dns = await fail("no-such-host.invalid", 22, "x", .password("x"))
        #expect(dns == "The address no-such-host.invalid can't be found.")
        #expect(Problem.from(dns).kind == .network)
        let login = await fail(host, port, "nobody-deckhand", .password("wrong"))
        #expect(login == "The server didn't accept the login for nobody-deckhand.")
        #expect(Problem.from(login).kind == .signIn)
        let closed = await fail(host, 1, "x", .password("x"))
        #expect(closed.hasPrefix("No answer from") || closed.contains("refused the connection"), "\(closed)")
        #expect(Problem.from(closed).kind == .network)
    }
}

/// Backups end to end on a disposable server: install restic, init a folder repository, back up, list, restore,
/// remove. Opt-in: DECKHAND_BACKUP_HOST/_PORT/_USER/_KEY.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_BACKUP_HOST"] != nil))
struct LiveBackupTests {
    @Test func backupListRestore() async throws {
        let env = ProcessInfo.processInfo.environment
        let key = try String(contentsOfFile: (env["DECKHAND_BACKUP_KEY"]! as NSString).expandingTildeInPath, encoding: .utf8)
        let conn = SSHConnection(
            endpoint: SSHEndpoint(host: env["DECKHAND_BACKUP_HOST"]!, port: Int(env["DECKHAND_BACKUP_PORT"] ?? "22")!, username: env["DECKHAND_BACKUP_USER"]!),
            credential: .privateKey(key, passphrase: nil))
        try await conn.connect(pinnedHostKey: nil, trustNewHostKey: { _, _ in true })
        let home = try await conn.run("printf '%s' \"$HOME\"", timeout: .seconds(10)).stdout
        _ = try await conn.run("mkdir -p ~/dh-backup-src/sub && echo hello > ~/dh-backup-src/sub/note.txt", timeout: .seconds(10))
        var plan = Backups.Plan(paths: ["\(home)/dh-backup-src"], target: .folder("\(home)/dh-backup-repo"), password: Backups.newPassword())
        plan.hour = 4
        let setup = try await conn.run(Backups.setupCommand(plan), timeout: .seconds(180))
        #expect(setup.stdout.contains("@@ok") && setup.stdout.contains("@@init"), "\(setup.stdout) \(setup.stderr)")
        #expect(setup.stdout.contains("@@restic 0.17"))
        // Run the nightly script in the foreground (runNow detaches).
        _ = try await conn.run("sh ~/.deckhand/backup/run.sh", timeout: .seconds(180))
        let status = Backups.parseStatus(try await conn.run(Backups.statusCommand, timeout: .seconds(60)).stdout)
        #expect(status.configured && status.schedule?.hour == 4)
        #expect(status.lastRun?.ok == true)
        let snap = try #require(status.snapshots.first)
        let list = Backups.parseList(try await conn.run(Backups.listCommand(snapshot: snap.id, path: "\(home)/dh-backup-src/sub"), timeout: .seconds(60)).stdout,
                                     parent: "\(home)/dh-backup-src/sub")
        #expect(list.map(\.name) == ["note.txt"])
        let restored = try await conn.run(Backups.restoreCommand(snapshot: snap.id, path: "\(home)/dh-backup-src/sub/note.txt"), timeout: .seconds(60)).stdout
        let dir = try #require(restored.split(separator: "\n").first { $0.hasPrefix("@@restored ") }).dropFirst(11)
        #expect(try await conn.run("cat '\(dir)\(home)/dh-backup-src/sub/note.txt'", timeout: .seconds(10)).stdout == "hello\n")
        #expect(try await conn.run(Backups.removeCommand, timeout: .seconds(20)).stdout.contains("@@ok"))
        #expect(try await conn.run("crontab -l 2>/dev/null | grep -c deckhand/backup; true", timeout: .seconds(10)).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        _ = try await conn.run("rm -rf ~/dh-backup-src ~/dh-backup-repo '\(dir)'", timeout: .seconds(20))
    }
}

/// Database dumps on a disposable server with Postgres (role for the login user) and a SQLite file.
/// Opt-in: DECKHAND_BACKUP_HOST/_PORT/_USER/_KEY plus DECKHAND_DB_TEST=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_DB_TEST"] != nil))
struct LiveDatabaseDumpTests {
    @Test func dumpTestRestoreRestore() async throws {
        let env = ProcessInfo.processInfo.environment
        let key = try String(contentsOfFile: (env["DECKHAND_BACKUP_KEY"]! as NSString).expandingTildeInPath, encoding: .utf8)
        let conn = SSHConnection(
            endpoint: SSHEndpoint(host: env["DECKHAND_BACKUP_HOST"]!, port: Int(env["DECKHAND_BACKUP_PORT"] ?? "22")!, username: env["DECKHAND_BACKUP_USER"]!),
            credential: .privateKey(key, passphrase: nil))
        try await conn.connect(pinnedHostKey: nil, trustNewHostKey: { _, _ in true })
        let dbs = DatabaseDumps.parseDiscovery(try await conn.run(DatabaseDumps.discoverCommand, timeout: .seconds(60)).stdout)
        let pg = try #require(dbs.first { $0.engine == .postgres && $0.name == "shop" })
        let lite = try #require(dbs.first { $0.engine == .sqlite && $0.name == "data.db" })
        let jobs = [(id: "pgshop", db: pg, keep: 7), (id: "lite", db: lite, keep: 7)]
        let saved = try await conn.run(DatabaseDumps.saveCommand(jobs, hour: 2, topic: ""), timeout: .seconds(120))
        #expect(saved.stdout.contains("@@ok"), "\(saved.stdout) \(saved.stderr)")
        let status = DatabaseDumps.parseStatus(try await conn.run(DatabaseDumps.statusCommand, timeout: .seconds(30)).stdout)
        #expect(status.schedule?.hour == 2 && status.jobs.count == 2)
        let pgDump = try #require(status.jobs.first { $0.id == "pgshop" }?.dumps.first)
        let liteDump = try #require(status.jobs.first { $0.id == "lite" }?.dumps.first)
        #expect(status.jobs.allSatisfy { $0.lastRun?.ok == true })
        let test = try await conn.run(DatabaseDumps.testRestoreCommand(pg, dump: pgDump.file), timeout: .seconds(120)).stdout
        #expect(test.contains("@@tables 2"), "\(test)")
        #expect(try await conn.run(DatabaseDumps.testRestoreCommand(lite, dump: liteDump.file), timeout: .seconds(60)).stdout.contains("@@integrity ok"))
        // Lose a table, then restore the dump over the live database.
        _ = try await conn.run("psql -d shop -qc 'drop table orders'", timeout: .seconds(20))
        #expect(try await conn.run(DatabaseDumps.restoreCommand(pg, dump: pgDump.file), timeout: .seconds(120)).stdout.contains("@@restored"))
        #expect(try await conn.run("psql -d shop -tAc 'select count(*) from orders'", timeout: .seconds(20)).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
        _ = try await conn.run(DatabaseDumps.saveCommand([], hour: 2, topic: "") + "\nrm -rf ~/.deckhand/db", timeout: .seconds(60))
        #expect(try await conn.run("crontab -l 2>/dev/null | grep -c deckhand/db; true", timeout: .seconds(10)).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }
}

/// The database browser on a disposable server (Postgres `shop`, SQLite file, Redis). Opt-in like LiveDatabaseDumpTests.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_DB_TEST"] != nil))
struct LiveDatabaseBrowserTests {
    @Test func browseQueryEditRedis() async throws {
        let env = ProcessInfo.processInfo.environment
        let key = try String(contentsOfFile: (env["DECKHAND_BACKUP_KEY"]! as NSString).expandingTildeInPath, encoding: .utf8)
        let conn = SSHConnection(
            endpoint: SSHEndpoint(host: env["DECKHAND_BACKUP_HOST"]!, port: Int(env["DECKHAND_BACKUP_PORT"] ?? "22")!, username: env["DECKHAND_BACKUP_USER"]!),
            credential: .privateKey(key, passphrase: nil))
        try await conn.connect(pinnedHostKey: nil, trustNewHostKey: { _, _ in true })
        func grid(_ db: DatabaseBrowser.Database, _ sql: String, writes: Bool = false) async throws -> Result<DatabaseBrowser.Grid, DatabaseBrowser.BrowserError> {
            DatabaseBrowser.parse(db, try await conn.run(DatabaseBrowser.sqlCommand(db, sql, allowWrites: writes), timeout: .seconds(30)).stdout)
        }
        let pg = DatabaseBrowser.Database(engine: .postgres, location: "local", name: "shop")
        let tables = try await grid(pg, DatabaseBrowser.tablesSQL(pg)).get()
        #expect(tables.rows.map { $0[0] } == ["public.customers", "public.orders"])
        #expect(try await grid(pg, DatabaseBrowser.primaryKeySQL(pg, table: "public.orders")).get().rows.first?.first == "id")
        let rows = try await grid(pg, DatabaseBrowser.rowsSQL(pg, table: "public.orders", filter: ("total", "42"))).get()
        #expect(rows.columns == ["id", "total"] && rows.rows.count == 1)
        // Read-only by default: a write fails and changes nothing.
        if case .success = try await grid(pg, "update orders set total = 0") { Issue.record("write should fail read-only") }
        let id = try #require(rows.rows.first?.first ?? nil)
        let update = try #require(DatabaseBrowser.updateSQL(pg, table: "public.orders", key: [("id", id)], column: "total", newValue: "43"))
        _ = try await grid(pg, update, writes: true).get()
        #expect(try await grid(pg, "select total from orders where id = \(id)").get().rows.first?.first == "43")
        _ = try await grid(pg, "update orders set total = 42 where id = \(id)", writes: true).get()

        // Ask in plain language: the schema the model gets, and a generated query run read-only.
        let schema = AskDatabase.schemaText(try await grid(pg, AskDatabase.schemaSQL(pg)).get())
        #expect(schema.contains("public.orders(id integer, total") && schema.contains("public.customers("))
        let asked = try #require(AskDatabase.sql(in: "```sql\nselect count(*) as n from orders\n```"))
        #expect(try await grid(pg, asked).get().rows.first?.first == "2")

        let lite = DatabaseBrowser.Database(engine: .sqlite, location: "/home/\(env["DECKHAND_BACKUP_USER"]!)/app/data.db", name: "data.db")
        #expect(try await grid(lite, DatabaseBrowser.tablesSQL(lite)).get().rows.first?.first == "notes")
        #expect(AskDatabase.schemaText(try await grid(lite, AskDatabase.schemaSQL(lite)).get()).hasPrefix("notes("))
        if case .success = try await grid(lite, "delete from notes") { Issue.record("sqlite read-only should refuse") }

        let redis = try #require(DatabaseBrowser.parseRedisDiscovery(try await conn.run(DatabaseBrowser.redisDiscoverCommand, timeout: .seconds(20)).stdout).first)
        let keysRun = try await conn.run(DatabaseBrowser.redisKeysCommand(redis, pattern: "*"), timeout: .seconds(20))
        let keys = DatabaseBrowser.parseRedisKeys(keysRun.stdout)
        #expect(keys.contains { $0.key == "user:7" && $0.type == "hash" }, "\(keysRun.stdout) | \(keysRun.stderr) | \(redis.location)")
        let value = try await conn.run(DatabaseBrowser.redisValueCommand(redis, key: "user:7", type: "hash"), timeout: .seconds(20)).stdout
        #expect(value.contains("@@ttl -1") && value.contains("Ann"))
    }
}

/// Deploys on a disposable server with git and a bare repo ~/src/app.git (a Python server that prints VERSION).
/// Opt-in: DECKHAND_DEPLOY_TEST=1 plus DECKHAND_BACKUP_HOST/_PORT/_USER/_KEY.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_DEPLOY_TEST"] != nil))
struct LiveDeployTests {
    @Test func deployAutoDeployRollBack() async throws {
        let env = ProcessInfo.processInfo.environment
        let key = try String(contentsOfFile: (env["DECKHAND_BACKUP_KEY"]! as NSString).expandingTildeInPath, encoding: .utf8)
        let conn = SSHConnection(
            endpoint: SSHEndpoint(host: env["DECKHAND_BACKUP_HOST"]!, port: Int(env["DECKHAND_BACKUP_PORT"] ?? "22")!, username: env["DECKHAND_BACKUP_USER"]!),
            credential: .privateKey(key, passphrase: nil))
        try await conn.connect(pinnedHostKey: nil, trustNewHostKey: { _, _ in true })
        func sh(_ c: String, _ t: Int = 120) async throws -> String { try await conn.run(c, timeout: .seconds(t)).stdout }
        func page() async throws -> String { try await sh("curl -s -m 5 http://127.0.0.1:8088/").trimmingCharacters(in: .whitespacesAndNewlines) }
        func push(_ version: String, broken: Bool = false) async throws {
            _ = try await sh("cd ~/src/work && echo \(version) > VERSION \(broken ? "&& echo 'syntax error(' >> server.py" : "") && git commit -qam '\(version)' && git push -q origin main")
        }
        let home = try await sh("printf '%s' \"$HOME\"")
        let app = Deploys.App(name: "demo", repo: "\(home)/src/app.git", start: "python3 server.py", health: "http://127.0.0.1:8088/", keep: 3, autoDeploy: true)
        #expect(try await sh(Deploys.saveCommand(app, topic: "")).contains("@@ok"))
        _ = try await sh("bash ~/.deckhand/apps/demo/deploy.sh; true")
        #expect(try await page() == "v1")
        var st = try #require(Deploys.parseStatus(try await sh(Deploys.statusCommand)).first)
        #expect(st.running && st.app.autoDeploy && st.deploys.first?.state == "live")
        let v1 = try #require(st.current)

        try await push("v2")
        _ = try await sh("bash ~/.deckhand/apps/demo/deploy.sh --if-changed; true")
        #expect(try await page() == "v2")
        _ = try await sh("bash ~/.deckhand/apps/demo/deploy.sh --if-changed; true")   // unchanged: no new deploy
        st = try #require(Deploys.parseStatus(try await sh(Deploys.statusCommand)).first)
        #expect(st.deploys.count == 2)

        try await push("v3", broken: true)
        _ = try await sh("bash ~/.deckhand/apps/demo/deploy.sh; true", 180)
        #expect(try await page() == "v2")                                               // rolled back by the health check
        st = try #require(Deploys.parseStatus(try await sh(Deploys.statusCommand)).first)
        #expect(st.deploys.first?.state == "rolledback")
        let log = try await sh(Deploys.logCommand("demo", stamp: st.deploys.first!.stamp))
        #expect(log.contains("@@failed health check"))

        #expect(try await sh(Deploys.rollbackCommand("demo", release: v1)).contains("@@ok"))
        try await Task.sleep(for: .seconds(2))
        #expect(try await page() == "v1")
        #expect(try await sh(Deploys.removeCommand("demo")).contains("@@ok"))
        try await Task.sleep(for: .seconds(2))
        #expect(try await page() == "")
        #expect(try await sh("crontab -l 2>/dev/null | grep -c deckhand-deploy; true").trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        // Leave the test repo at its first commit for the next run.
        _ = try await sh("cd ~/src/work && rm -rf __pycache__ && git reset -q --hard $(git rev-list --max-parents=0 HEAD) && git push -qf origin main; true")
    }
}

/// Evidence scripts on a real Linux server (set DECKHAND_TEST_HOST/_PORT/_USER/_KEY).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_TEST_HOST"] != nil))
struct LiveEvidenceTests {
    func connection() async throws -> SSHConnection { try await LiveSSHTests().connection() }

    @Test func lockdownEvidence() async throws {
        let conn = try await connection()
        let dir = "/tmp/dh-ev-\(UUID().uuidString.prefix(6).lowercased())"
        let r = try await conn.run(Lockdown.evidenceScript(dir), timeout: .seconds(120))
        #expect(r.stdout.contains("@@evidence \(dir)"))
        let files = try await conn.run("ls '\(dir)'", timeout: .seconds(10)).stdout
        #expect(files.contains("processes.txt") && files.contains("connections.txt") && files.contains("changed-files.txt"))
        _ = try await conn.run("rm -rf '\(dir)'", timeout: .seconds(10))
    }

    @Test func incidentEvidence() async throws {
        let conn = try await connection()
        let r = try await conn.run(Incident.evidenceCommand(url: "http://127.0.0.1:9/"), timeout: .seconds(60))
        let e = Incident.parse(r.stdout)
        #expect(e.first?.title == "Request")
        #expect(e.first?.text.contains("HTTP 000") == true)
        #expect(e.contains { $0.title == "Load and memory" })
    }
}

/// One-tap app installs against a server with Docker (DECKHAND_TEST_* and DECKHAND_TEMPLATES_TEST=1): every compose
/// file passes `docker compose config`; Redis and Uptime Kuma are installed under throwaway names, answer, and are
/// removed again with their data.
struct LiveAppTemplateTests {
    @Test func installCheckRemove() async throws {
        guard ProcessInfo.processInfo.environment["DECKHAND_TEMPLATES_TEST"] == "1" else { return }
        let conn = try await LiveSSHTests().connection()
        do {
            for t in AppTemplates.catalog {
                let vars = (["PORT=18000", "DOMAIN=example.com", "URL=https://example.com", "SCHEME=https", "SECURE=true"]
                    + t.secrets.map { "\($0.key)=x" }).joined(separator: "\n")
                let r = try await conn.run("""
                    d=$(mktemp -d) && cd "$d" && printf '%s\\n' \(ShellQuote.quote(vars)) > .env && printf '%s\\n' \(ShellQuote.quote(t.compose)) > docker-compose.yml \
                    && docker compose config -q && echo valid; cd / && rm -rf "$d"
                    """, timeout: .seconds(30))
                #expect(r.stdout.contains("valid"), "\(t.id): \(r.stderr)")
            }
            for id in ["redis", "uptime-kuma"] {
                let name = "dh-test-\(id)-\(UUID().uuidString.prefix(4).lowercased())"
                let plan = AppTemplates.Plan(template: AppTemplates.template(id)!, name: name)
                let result = AppTemplates.parseInstall(try await conn.run(AppTemplates.installCommand(plan), timeout: .seconds(600)).stdout)
                #expect(result.ok && !result.slow && result.failure == nil, "\(id): \(result)")
                let app = AppTemplates.parseList(try await conn.run(AppTemplates.listCommand, timeout: .seconds(30)).stdout).first { $0.name == plan.name }
                #expect(app?.running == app?.total && (app?.running ?? 0) >= 1, "\(id) not running")
                if id == "redis", let pw = result.secrets["REDIS_PASSWORD"] {
                    let ping = try await conn.run("docker compose -p \(plan.project) exec -T redis redis-cli -a \(ShellQuote.quote(pw)) --no-auth-warning ping", timeout: .seconds(30))
                    #expect(ping.stdout.contains("PONG"))
                } else if let port = result.port {
                    let code = try await conn.run("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:\(port)/", timeout: .seconds(30)).stdout
                    #expect(["200", "302"].contains(code), "uptime-kuma answered \(code)")
                }
                let removed = try await conn.run(AppTemplates.actionCommand(.removeWithData, name: plan.name), timeout: .seconds(120))
                #expect(removed.stdout.contains("@@ok"), "\(removed.stdout)")
                #expect(try await conn.run("docker volume ls -q | grep -c '^\(plan.project)_' || true", timeout: .seconds(30)).stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "0")
            }
        } catch { Issue.record(error) }
        await conn.disconnect()
    }
}

/// Expiry warnings on the disposable server (DECKHAND_BACKUP_* and DECKHAND_EXPIRY_TEST=1): a real certificate and
/// RDAP lookup for github.com, a deliberately expired certificate at expired.badssl.com, pushes to a fake ntfy on the
/// server — once per step, not again on the next run. Removes everything afterwards.
struct LiveExpiryTests {
    @Test func certificatesDomainsAndWarnings() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_EXPIRY_TEST"] == "1" else { return }
        let key = try String(contentsOfFile: (env["DECKHAND_BACKUP_KEY"]! as NSString).expandingTildeInPath, encoding: .utf8)
        let conn = SSHConnection(
            endpoint: SSHEndpoint(host: env["DECKHAND_BACKUP_HOST"]!, port: Int(env["DECKHAND_BACKUP_PORT"] ?? "22")!, username: env["DECKHAND_BACKUP_USER"]!),
            credential: .privateKey(key, passphrase: nil))
        try await conn.connect(pinnedHostKey: nil, trustNewHostKey: { _, _ in true })
        do {
            let port = Int.random(in: 41000...41900)
            let fake = "import http.server,sys\nclass H(http.server.BaseHTTPRequestHandler):\n def do_POST(s):\n  n=int(s.headers.get('Content-Length',0)); open(sys.argv[2],'a').write(s.rfile.read(n).decode()+'\\n'); s.send_response(200); s.end_headers()\n def log_message(s,*a): pass\nhttp.server.HTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()\n"
            _ = try await conn.run("printf '%s' \(ShellQuote.quote(fake)) > /tmp/dh-ntfy.py; rm -f /tmp/dh-pushes; (python3 /tmp/dh-ntfy.py \(port) /tmp/dh-pushes > /dev/null 2>&1 < /dev/null &); sleep 1", timeout: .seconds(15))
            #expect(try await conn.run(Expiry.installCommand(topic: "http://127.0.0.1:\(port)/t"), timeout: .seconds(30)).stdout.contains("@@ok"))
            _ = try await conn.run(Expiry.addCommand("github.com") + "\n" + Expiry.addCommand("expired.badssl.com"), timeout: .seconds(15))
            _ = try await conn.run(Expiry.runNowCommand, timeout: .seconds(120))
            let s = Expiry.parseStatus(try await conn.run(Expiry.statusCommand, timeout: .seconds(30)).stdout)
            #expect(s.installed && s.entries.count == 2)
            let gh = try #require(s.entries.first { $0.domain == "github.com" })
            #expect((gh.daysLeft(gh.certificateEnd) ?? -1) > 0, "github cert: \(gh)")
            #expect((gh.daysLeft(gh.registrationEnd) ?? -1) > 30, "github domain: \(gh)")
            let bad = try #require(s.entries.first { $0.domain == "expired.badssl.com" })
            #expect((bad.daysLeft(bad.certificateEnd) ?? 1) < 0, "badssl cert: \(bad)")
            let pushes = try await conn.run("cat /tmp/dh-pushes", timeout: .seconds(10)).stdout
            #expect(pushes.contains("The certificate for expired.badssl.com has expired."), "\(pushes)")
            #expect(!pushes.contains("github.com"))
            // The next run doesn't repeat the warning.
            _ = try await conn.run(Expiry.runNowCommand, timeout: .seconds(120))
            #expect(try await conn.run("grep -c 'has expired' /tmp/dh-pushes", timeout: .seconds(10)).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
            _ = try await conn.run(Expiry.uninstallCommand + "; pkill -f 'dh-ntfy.py \(port)'; rm -f /tmp/dh-ntfy.py /tmp/dh-pushes", timeout: .seconds(15))
            #expect(!(try await conn.run("crontab -l 2>/dev/null", timeout: .seconds(10)).stdout.contains("expiry")))
        } catch { Issue.record(error) }
        await conn.disconnect()
    }
}

/// Network tools on the disposable server (DECKHAND_BACKUP_*, DECKHAND_NET_TEST=1) with whatever tools it has.
struct LiveNetworkToolsTests {
    @Test func toolsOnAServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_NET_TEST"] == "1" else { return }
        let key = try String(contentsOfFile: (env["DECKHAND_BACKUP_KEY"]! as NSString).expandingTildeInPath, encoding: .utf8)
        let conn = SSHConnection(
            endpoint: SSHEndpoint(host: env["DECKHAND_BACKUP_HOST"]!, port: Int(env["DECKHAND_BACKUP_PORT"] ?? "22")!, username: env["DECKHAND_BACKUP_USER"]!),
            credential: .privateKey(key, passphrase: nil))
        try await conn.connect(pinnedHostKey: nil, trustNewHostKey: { _, _ in true })
        func run(_ tool: NetworkTools.Tool, _ target: String, port: Int = 443) async throws -> NetworkTools.Result {
            NetworkTools.parse(tool, try await conn.run(NetworkTools.serverCommand(tool, target: target, port: port), timeout: .seconds(90)).stdout)
        }
        do {
            let dns = try await run(.dns, "github.com")
            #expect(dns.ok == true, "\(dns)")
            #expect(try await run(.port, "github.com").ok == true)
            #expect(try await run(.port, "127.0.0.1", port: 1).ok == false)
            let http = try await run(.http, "https://github.com/")
            let httpRaw = try await conn.run(NetworkTools.serverCommand(.http, target: "https://github.com/"), timeout: .seconds(30))
            #expect(http.ok == true && http.summary.first == "Status 200", "\(http) — \(httpRaw.stdout) \(httpRaw.stderr)")
            let ping = try await run(.ping, "github.com")
            print("ping:", ping.summary, ping.raw.prefix(120))
            let trace = try await run(.traceroute, "github.com")
            print("traceroute:", trace.summary)
            #expect(!trace.summary.isEmpty)
        } catch { Issue.record(error) }
        await conn.disconnect()
    }
}

/// Metrics history on the disposable server (DECKHAND_BACKUP_*, DECKHAND_METRICS_TEST=1): install, a real sample,
/// remove.
struct LiveMetricsHistoryTests {
    @Test func samplerOnAServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_METRICS_TEST"] == "1" else { return }
        let key = try String(contentsOfFile: (env["DECKHAND_BACKUP_KEY"]! as NSString).expandingTildeInPath, encoding: .utf8)
        let conn = SSHConnection(
            endpoint: SSHEndpoint(host: env["DECKHAND_BACKUP_HOST"]!, port: Int(env["DECKHAND_BACKUP_PORT"] ?? "22")!, username: env["DECKHAND_BACKUP_USER"]!),
            credential: .privateKey(key, passphrase: nil))
        try await conn.connect(pinnedHostKey: nil, trustNewHostKey: { _, _ in true })
        do {
            #expect(try await conn.run(MetricsHistory.installCommand, timeout: .seconds(30)).stdout.contains("@@ok"))
            _ = try await conn.run("$HOME/.deckhand/metrics/run.sh", timeout: .seconds(30))
            let r = MetricsHistory.parse(try await conn.run(MetricsHistory.readCommand(), timeout: .seconds(30)).stdout)
            #expect(r.installed && r.samples.count == 2, "\(r)")
            let s = try #require(r.samples.last)
            #expect(s.memory > 0 && s.memory < 100 && s.disk > 0 && s.rxBytes > 0 && s.cpu >= 0, "\(s)")
            #expect(MetricsHistory.series(r.samples, metric: .network).count == 1)
            _ = try await conn.run(MetricsHistory.uninstallCommand, timeout: .seconds(30))
            #expect(!(try await conn.run("crontab -l 2>/dev/null", timeout: .seconds(10)).stdout.contains("metrics")))
        } catch { Issue.record(error) }
        await conn.disconnect()
    }
}

/// Cron heartbeats on the disposable server (DECKHAND_BACKUP_*, DECKHAND_CRON_TEST=1): two test lines are watched,
/// runs are recorded through the wrapper, a failure and a missed run push to a fake ntfy, and unwatching restores the
/// crontab exactly. The test lines are removed afterwards.
struct LiveCronWatchTests {
    @Test func watchRunMissUnwatch() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_CRON_TEST"] == "1" else { return }
        let key = try String(contentsOfFile: (env["DECKHAND_BACKUP_KEY"]! as NSString).expandingTildeInPath, encoding: .utf8)
        let conn = SSHConnection(
            endpoint: SSHEndpoint(host: env["DECKHAND_BACKUP_HOST"]!, port: Int(env["DECKHAND_BACKUP_PORT"] ?? "22")!, username: env["DECKHAND_BACKUP_USER"]!),
            credential: .privateKey(key, passphrase: nil))
        try await conn.connect(pinnedHostKey: nil, trustNewHostKey: { _, _ in true })
        func sh(_ c: String) async throws -> String { try await conn.run(c, timeout: .seconds(60)).stdout }
        let good = #"17 3 * * * echo dh-test-good-$(date +\%Y)"#
        let bad = "*/5 * * * * echo dh-test-bad; exit 3"
        do {
            let port = Int.random(in: 41000...41900)
            let fake = "import http.server,sys\nclass H(http.server.BaseHTTPRequestHandler):\n def do_POST(s):\n  n=int(s.headers.get('Content-Length',0)); open(sys.argv[2],'a').write(s.rfile.read(n).decode()+'\\n'); s.send_response(200); s.end_headers()\n def log_message(s,*a): pass\nhttp.server.HTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()\n"
            _ = try await sh("printf '%s' \(ShellQuote.quote(fake)) > /tmp/dh-ntfy.py; rm -f /tmp/dh-pushes; (python3 /tmp/dh-ntfy.py \(port) /tmp/dh-pushes > /dev/null 2>&1 < /dev/null &); sleep 1")
            let before = try await sh("crontab -l 2>/dev/null")
            _ = try await sh("{ crontab -l 2>/dev/null; printf '%s\\n' \(ShellQuote.quote(good)) \(ShellQuote.quote(bad)); } | crontab -")
            let topic = "http://127.0.0.1:\(port)/t"
            #expect(try await sh(CronWatch.watchCommand(line: good, name: "Good job", topic: topic, id: "dhgood")).contains("@@watched dhgood"))
            #expect(try await sh(CronWatch.watchCommand(line: bad, name: "Bad job", topic: topic, id: "dhbad")).contains("@@watched dhbad"))
            let tab = try await sh("crontab -l")
            #expect(tab.contains("wrap.sh dhgood # deckhand-cronwatch dhgood") && tab.contains("cronwatch/check.sh") && !tab.contains("dh-test-good"))

            // Runs as cron would run them.
            _ = try await sh("$HOME/.deckhand/cronwatch/wrap.sh dhgood; $HOME/.deckhand/cronwatch/wrap.sh dhbad; true")
            var s = CronWatch.parseStatus(try await sh(CronWatch.statusCommand))
            #expect(s.watches["dhgood"]?.last?.exitCode == 0 && s.watches["dhgood"]?.output.first?.hasPrefix("dh-test-good-20") == true)
            #expect(s.watches["dhbad"]?.last?.exitCode == 3)
            // A missed run: pretend the last start was a day ago.
            _ = try await sh("echo $(( $(date +%s) - 86400 )) > $HOME/.deckhand/cronwatch/dhbad.started; $HOME/.deckhand/cronwatch/check.sh; $HOME/.deckhand/cronwatch/check.sh; sleep 1")
            s = CronWatch.parseStatus(try await sh(CronWatch.statusCommand))
            #expect(s.watches["dhbad"]?.missingSince != nil && s.watches["dhgood"]?.missingSince == nil)
            let pushes = try await sh("cat /tmp/dh-pushes")
            #expect(pushes.contains("Cron job failed (exit 3): Bad job") && pushes.contains("Cron job hasn't run: Bad job"), "\(pushes)")
            #expect(pushes.components(separatedBy: "hasn't run").count == 2, "missed-run push repeated")

            // Unwatch: the original lines come back exactly.
            _ = try await sh(CronWatch.unwatchCommand(id: "dhgood") + "\n" + CronWatch.unwatchCommand(id: "dhbad"))
            let restored = try await sh("crontab -l")
            #expect(restored.contains(good) && restored.contains(bad) && !restored.contains("cronwatch"))
            _ = try await sh("crontab -l | grep -v -e dh-test-good -e dh-test-bad | crontab -; pkill -f 'dh-ntfy.py \(port)'; rm -f /tmp/dh-ntfy.py /tmp/dh-pushes")
            #expect(try await sh("crontab -l 2>/dev/null") == before)
        } catch { Issue.record(error) }
        await conn.disconnect()
    }
}
