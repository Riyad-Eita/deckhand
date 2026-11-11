import CryptoKit
import Foundation
import Testing
@testable import DeckhandCore

/// Runs the real checker (`hook.py`) with python3 against a throwaway home folder.
@Suite(.serialized) struct HouseRulesTests {
    struct Home {
        let path: String
        func sh(_ cmd: String) async throws -> CommandResult {
            try await LocalShell().run("unset CODEX_HOME; HOME='\(path)' PATH=/usr/bin:/bin /bin/sh -c \(ShellQuote.quote(cmd))", timeout: .seconds(20))
        }
        /// Feeds one hook input to the checker like Claude Code or Codex would.
        func hook(_ engine: String, _ input: JSONValue) async throws -> CommandResult {
            let b64 = Data(input.jsonString().utf8).base64EncodedString()
            return try await sh("printf '%s' '\(b64)' | base64 -d | python3 ~/.deckhand/rules/hook.py \(engine)")
        }
        func read(_ rel: String) throws -> String { try String(contentsOfFile: path + "/" + rel, encoding: .utf8) }
    }

    func install(_ rules: HouseRules, prepare: (String) throws -> Void = { _ in }) async throws -> (Home, HouseRules.InstallResult) {
        let h = Home(path: FileManager.default.temporaryDirectory.appending(path: "rules-\(UUID().uuidString.prefix(6))").path)
        try FileManager.default.createDirectory(atPath: h.path, withIntermediateDirectories: true)
        try prepare(h.path)
        let r = try await h.sh(rules.installCommand())
        return (h, HouseRules.InstallResult(output: r.stdout))
    }

    func bash(_ command: String, cwd: String = "/tmp") -> JSONValue {
        ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": .string(command)], "cwd": .string(cwd)]
    }

    func blocked(_ h: Home, _ input: JSONValue, engine: String = "claude") async throws -> HouseRules.Block? {
        let r = try await h.hook(engine, input)
        if r.exitCode == 0 { return nil }
        #expect(r.exitCode == 2)
        return HouseRules.block(in: r.stderr)
    }

    @Test func protectedPaths() async throws {
        let (h, result) = try await install(HouseRules(protectedPaths: ["/srv/db", "~/secrets"]))
        #expect(result.ok)
        // Claude Code writes, Codex patches, shell commands that mention the folder
        let write: JSONValue = ["tool_name": "Write", "tool_input": ["file_path": "/srv/db/main.sqlite", "content": "x"], "cwd": "/tmp"]
        #expect(try await blocked(h, write)?.ruleID == "path:0")
        let patch: JSONValue = ["tool_name": "apply_patch", "tool_input": ["command": "*** Begin Patch\n*** Update File: /srv/db/conf.ini\n@@\n-a\n+b\n*** End Patch"], "cwd": "/tmp"]
        #expect(try await blocked(h, patch, engine: "codex")?.ruleID == "path:0")
        #expect(try await blocked(h, bash("rm -rf /srv/db/data"))?.title == "Hands off /srv/db")
        #expect(try await blocked(h, bash("tar czf /tmp/x.tgz \"$HOME/secrets\""))?.ruleID == "path:1")
        #expect(try await blocked(h, bash("cat \(h.path)/secrets/token"))?.ruleID == "path:1")
        #expect(try await blocked(h, bash("ls", cwd: "/srv/db/sub"))?.ruleID == "path:0")
        let relative: JSONValue = ["tool_name": "Edit", "tool_input": ["file_path": "../db/x"], "cwd": "/srv/app"]
        #expect(try await blocked(h, relative)?.ruleID == "path:0")
        // neighbours are fine
        #expect(try await blocked(h, bash("ls /srv/dbx /srv/app")) == nil)
        let other: JSONValue = ["tool_name": "Write", "tool_input": ["file_path": "/srv/app/x"], "cwd": "/tmp"]
        #expect(try await blocked(h, other) == nil)
        #expect(try await blocked(h, ["tool_name": "Read", "tool_input": ["file_path": "/srv/db/x"]]) == nil)
    }

    @Test func forbiddenCommandsAndOpenPorts() async throws {
        let (h, _) = try await install(HouseRules(forbiddenCommands: ["docker system prune", "npm publish"], noOpenPorts: true))
        #expect(try await blocked(h, bash("sudo docker system prune -af"))?.ruleID == "command:0")
        #expect(try await blocked(h, bash("cd app && npm  publish --access public"))?.ruleID == "command:1")
        #expect(try await blocked(h, bash("docker system df")) == nil)
        #expect(try await blocked(h, bash("pnpm publish")) == nil)
        for cmd in ["sudo ufw allow 8080/tcp", "iptables -I INPUT -p tcp --dport 80 -j ACCEPT", "firewall-cmd --add-port=80/tcp",
                    "docker run -d -p 80:80 nginx"] {
            #expect(try await blocked(h, bash(cmd))?.ruleID == "noOpenPorts", "\(cmd)")
        }
        for cmd in ["ufw status", "docker run --rm alpine echo hi", "iptables -L"] {
            #expect(try await blocked(h, bash(cmd)) == nil, "\(cmd)")
        }
    }

    @Test func readOnlyMode() async throws {
        let (h, _) = try await install(HouseRules(readOnly: true))
        for cmd in ["ls -la /etc 2>/dev/null", "cat a.txt | grep -n foo | head -5", "git status && git log --oneline -5",
                    "systemctl status nginx", "journalctl -u app -n 50 --no-pager", "find . -name '*.py'", "df -h; free -m",
                    "docker ps -a", "ip addr show", "sed -n 1,20p app.py", "curl -sI https://example.com", "ps aux 2>&1"] {
            #expect(try await blocked(h, bash(cmd)) == nil, "\(cmd)")
        }
        for cmd in ["echo hi > f.txt", "rm a.txt", "sed -i 's/a/b/' f", "systemctl restart nginx", "find . -delete",
                    "ip link set eth0 down", "cat $(echo /etc/passwd)", "sort -o out.txt in.txt", "npm install",
                    "curl -o x https://example.com", "journalctl --vacuum-time=1d", "git push"] {
            #expect(try await blocked(h, bash(cmd))?.ruleID == "readOnly", "\(cmd)")
        }
        let write: JSONValue = ["tool_name": "Edit", "tool_input": ["file_path": "/tmp/a"]]
        #expect(try await blocked(h, write)?.ruleID == "readOnly")
    }

    @Test func quietHours() async throws {
        let (h, _) = try await install(HouseRules(quietHours: .init(start: "00:00", end: "23:59", days: [1, 2, 3, 4, 5, 6, 7], timeZone: "UTC")))
        #expect(try await blocked(h, bash("sudo systemctl restart nginx"))?.ruleID == "quietHours")
        #expect(try await blocked(h, bash("docker compose up -d"))?.ruleID == "quietHours")
        #expect(try await blocked(h, bash("sudo reboot"))?.ruleID == "quietHours")
        #expect(try await blocked(h, bash("systemctl status nginx")) == nil)
        // the window itself: Wed 2026-11-11 10:00 UTC = 1794391200
        func inWindow(_ q: String, _ ts: Int) async throws -> Bool {
            let r = try await h.sh("cd ~/.deckhand/rules && python3 -c 'import hook; print(hook.in_window(\(q), \(ts)))'")
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "True"
        }
        let wed10 = 1_794_391_200
        let business = #"{"start": "09:00", "end": "18:00", "days": [1,2,3,4,5], "timeZone": "UTC"}"#
        #expect(try await inWindow(business, wed10))
        #expect(try await !inWindow(business, wed10 + 9 * 3600))           // 19:00
        #expect(try await !inWindow(business, wed10 + 3 * 86400))          // Saturday
        #expect(try await inWindow(#"{"start": "09:00", "end": "18:00", "days": [3], "timeZone": "Europe/Berlin"}"#, wed10))
        let night = #"{"start": "22:00", "end": "06:00", "days": [5], "timeZone": "UTC"}"#
        #expect(try await inWindow(night, wed10 + 2 * 86400 + 13 * 3600))  // Friday 23:00
        #expect(try await inWindow(night, wed10 + 3 * 86400 - 7 * 3600))   // Saturday 03:00, window started Friday
        #expect(try await !inWindow(night, wed10 - 7 * 3600))              // Wednesday 03:00 (started Tuesday)
    }

    @Test func allowOnce() async throws {
        let (h, _) = try await install(HouseRules(forbiddenCommands: ["reboot"]))
        let call = bash("sudo reboot")
        let block = try #require(try await blocked(h, call))
        let fp = try #require(block.fingerprint)
        #expect(try await h.sh(try #require(HouseRules.allowOnceCommand(fp))).stdout.contains("@@ok"))
        #expect(try await blocked(h, bash("reboot now")) != nil)   // only exactly that call
        #expect(try await blocked(h, call) == nil)
        #expect(try await blocked(h, call) != nil)                 // once
        // expired permissions don't count
        _ = try await h.sh(try #require(HouseRules.allowOnceCommand(fp, now: Date().addingTimeInterval(-3600))))
        #expect(try await blocked(h, call) != nil)
        #expect(HouseRules.allowOnceCommand("x; rm -rf /") == nil)
    }

    @Test func ownKeyAgentVerdict() async throws {
        let (h, _) = try await install(HouseRules(protectedPaths: ["~/db"]))
        let call = ToolCall(id: "1", name: "write_file", input: ["path": "db/x.sql", "content": "x"])
        let cmd = try #require(HouseRules.checkCommand(call, workingDirectory: "~"))
        let block = try #require(HouseRules.parseVerdict(try await h.sh(cmd).stdout))
        #expect(block.ruleID == "path:0" && block.fingerprint == nil)
        let ok = ToolCall(id: "2", name: "run_command", input: ["command": "ls ~/web"])
        #expect(HouseRules.parseVerdict(try await h.sh(try #require(HouseRules.checkCommand(ok, workingDirectory: "~"))).stdout) == nil)
        #expect(HouseRules.checkCommand(ToolCall(id: "3", name: "read_file", input: ["path": "db/x"]), workingDirectory: "~") == nil)
        // no rules installed: nothing to say
        _ = try await h.sh(HouseRules.uninstallCommand)
        #expect(try await h.sh(cmd).stdout.isEmpty)
    }

    @Test func wiresClaudeCodeAndCodexWithoutLosingTheirSettings() async throws {
        let (h, result) = try await install(HouseRules(readOnly: true)) { home in
            try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
            try #"{"model": "opus", "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "mine.sh"}]}]}}"#
                .write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
            try #"{"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "mine.sh"}]}]}}"#
                .write(toFile: home + "/.codex/hooks.json", atomically: true, encoding: .utf8)
            try "model = \"gpt-5\"\n\n[projects.\"/srv\"]\ntrust_level = \"trusted\"\n".write(toFile: home + "/.codex/config.toml", atomically: true, encoding: .utf8)
        }
        #expect(result.ok && result.claudeCode && result.codex && result.errors.isEmpty)
        _ = try await h.sh(HouseRules(readOnly: true).installCommand())   // twice: still one entry each

        let claude = try JSONValue.parse(try h.read(".claude/settings.json"))
        #expect(claude["model"]?.stringValue == "opus")
        let groups = try #require(claude["hooks"]?["PreToolUse"]?.arrayValue)
        #expect(groups.count == 2)
        #expect(groups[1]["hooks"]?.arrayValue?.first?["command"]?.stringValue?.contains(".deckhand/rules/hook.py\" claude") == true)

        let codexHooks = try #require(try JSONValue.parse(try h.read(".codex/hooks.json"))["hooks"]?["PreToolUse"]?.arrayValue)
        #expect(codexHooks.count == 2)
        let command = "python3 \(h.path)/.deckhand/rules/hook.py codex"
        #expect(codexHooks[1]["hooks"]?.arrayValue?.first?["command"]?.stringValue == command)
        // Codex runs only trusted hooks: the hash of the normalized declaration, keyed by file, event and position.
        let identity = #"{"event_name":"pre_tool_use","hooks":[{"async":false,"command":"\#(command)","timeout":600,"type":"command"}]}"#
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let toml = try h.read(".codex/config.toml")
        #expect(toml.hasPrefix("model = \"gpt-5\"\n\n[projects.\"/srv\"]\ntrust_level = \"trusted\"\n"))
        #expect(toml.contains("[hooks.state.\"\(h.path)/.codex/hooks.json:pre_tool_use:1:0\"]\ntrusted_hash = \"sha256:\(hash)\""))
        #expect(toml.components(separatedBy: "# deckhand:rules").count == 2)

        let off = try await h.sh(HouseRules.uninstallCommand)
        #expect(off.stdout.contains("@@ok"))
        #expect(try JSONValue.parse(try h.read(".claude/settings.json"))["hooks"]?["PreToolUse"]?.arrayValue?.count == 1)
        #expect(try JSONValue.parse(try h.read(".codex/hooks.json"))["hooks"]?["PreToolUse"]?.arrayValue?.count == 1)
        #expect(try h.read(".codex/config.toml") == "model = \"gpt-5\"\n\n[projects.\"/srv\"]\ntrust_level = \"trusted\"\n")
        #expect(!FileManager.default.fileExists(atPath: h.path + "/.deckhand/rules"))
    }

    @Test func damagedRulesBlockChanges() async throws {
        let (h, _) = try await install(HouseRules(noOpenPorts: true))
        _ = try await h.sh("echo '{oops' > ~/.deckhand/rules/rules.json")
        #expect(try await blocked(h, bash("touch x")) != nil)
        #expect(try await blocked(h, bash("ls")) == nil)
    }

    @Test func parsesRulesAndMarkers() throws {
        #expect(HouseRules.decode("") == nil)
        #expect(HouseRules.decode("{}") == nil)
        let rules = HouseRules(protectedPaths: ["/srv/db"], quietHours: .init(timeZone: "UTC"), maxSpendUSD: 2)
        #expect(HouseRules.decode(rules.encoded()) == rules)
        let claude = "PreToolUse:Bash hook error: [python3 \"$HOME/.deckhand/rules/hook.py\" claude]: Blocked by house rule: Hands off /srv/db. The server owner set this rule in Deckhand; don't try to get around it. Tell the user what you wanted to do: they can allow it once in the app. [deckhand-rule path:0 0123456789ab]"
        let block = try #require(HouseRules.block(in: claude))
        #expect(block == HouseRules.Block(ruleID: "path:0", title: "Hands off /srv/db", fingerprint: "0123456789ab"))
        #expect(rules.title(for: block) == "Hands off /srv/db")
        #expect(HouseRules.block(in: "exit code 2") == nil)
        let r = HouseRules.InstallResult(output: "@@claude\n@@error codex: bad json\n@@ok\n")
        #expect(r.ok && r.claudeCode && !r.codex && r.errors == ["codex: bad json"])
        #expect(!HouseRules.InstallResult(output: "@@nopython\n").ok)
        #expect(CLIModels.flags(.claudeCode, CLIOptions(maxBudgetUSD: 2.5)) == " --max-budget-usd 2.50")
        #expect(CLIModels.flags(.codex, CLIOptions(maxBudgetUSD: 2.5)) == "")
    }

    @Test func agentAlwaysAsksWhenARuleIsBroken() async throws {
        let call = ToolCall(id: "t1", name: "run_command", input: ["command": "echo hi"])
        let provider = ScriptedProvider([
            [.completed(Message(role: .assistant, blocks: [.toolUse(call)]), .toolUse, Usage())],
            [.completed(Message(role: .assistant, blocks: [.text("ok")]), .endTurn, Usage())],
        ])
        let asked = Locked<ApprovalRequest?>(nil)
        let agent = Agent(
            provider: provider, shell: LocalShell(), tools: ServerTools.all(workingDirectory: "/tmp"), policy: .auto, system: "s",
            ruleCheck: { _ in HouseRules.Block(ruleID: "readOnly", title: "Read-only mode") },
            approve: { req in asked.set(req); return .deny(reason: nil) })
        for try await _ in agent.run(history: [], userMessage: .user("x")) {}
        #expect(asked.value?.rule?.ruleID == "readOnly")
        guard case .toolResult(let r) = provider.requests[1].messages[2].blocks[0] else { Issue.record("no result"); return }
        #expect(r.isError && r.content.hasPrefix("Blocked by house rule: Read-only mode."))
    }

    /// A fake ntfy: records the push, then answers on <topic>-reply with `answer:<fingerprint>` (or never).
    func fakeNtfy(_ dir: String, port: Int, answer: String) async throws {
        let py = """
        import http.server, json, re, sys
        fp = [None]
        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get('Content-Length', 0)); body = self.rfile.read(n).decode()
                acts = self.headers.get('Actions', '')
                m = re.search(r'(allow|deny):([0-9a-f]{12})', acts); fp[0] = m.group(2) if m else None
                open(sys.argv[2] + '/push.txt', 'a').write(json.dumps({'path': self.path, 'actions': acts, 'body': body, 'priority': self.headers.get('Priority')}) + '\\n')
                self.send_response(200); self.end_headers()
            def do_GET(self):
                self.send_response(200); self.end_headers()
                if fp[0] and sys.argv[3] != 'none' and '-reply/json' in self.path:
                    self.wfile.write((json.dumps({'message': sys.argv[3] + ':' + fp[0] + ':test-phone'}) + '\\n').encode())
            def log_message(self, *a): pass
        http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
        """
        try py.write(toFile: dir + "/ntfy.py", atomically: true, encoding: .utf8)
        _ = try await LocalShell().run("(python3 '\(dir)/ntfy.py' \(port) '\(dir)' \(answer) >/dev/null 2>&1 &); sleep 1", timeout: .seconds(10))
    }

    @Test func asksOnTheLockScreen() async throws {
        for (answer, command, expectExit, risky) in [("allow", "rm /srv/db/x", Int32(0), false), ("deny", "rm -rf /tmp/old", Int32(2), true), ("none", "rm /srv/db/y", Int32(2), false)] {
            let port = Int.random(in: 47001...49000)
            let ask = HouseRules.Ask(topic: "http://127.0.0.1:\(port)/t", server: "SERVER-ID", minutes: 0)
            var rules = HouseRules(protectedPaths: ["/srv/db"], ask: ask)
            rules.ask?.minutes = answer == "none" ? 0 : 1
            let (h, result) = try await install(rules)
            #expect(result.ok)
            try await fakeNtfy(h.path, port: port, answer: answer)
            defer { Task { _ = try? await LocalShell().run("pkill -f 'ntfy.py \(port)'", timeout: .seconds(5)) } }
            let b64 = Data(bash(command).jsonString().utf8).base64EncodedString()
            let r = try await h.sh("printf '%s' '\(b64)' | base64 -d | DECKHAND_ASK_POLL=0.2 python3 ~/.deckhand/rules/hook.py claude")
            #expect(r.exitCode == expectExit, "\(answer): \(r.stderr)")
            let push = try h.read("push.txt")
            #expect(push.contains("\"path\": \"/t\"") && push.contains("\"priority\": \"high\""))
            #expect(push.contains("deckhand://approve/SERVER-ID/") == risky)
            if answer == "deny" { #expect(r.stderr.contains("said no")) }
            if answer == "none" { #expect(r.stderr.contains("Blocked by house rule")) }
            if answer != "none" { #expect(try h.read(".deckhand/rules/answers.log").contains("\(answer) Claude Code test-phone")) }
        }
    }

    @Test func noAskWithoutTopic() async throws {
        let (h, _) = try await install(HouseRules(protectedPaths: ["/srv/db"]))
        #expect(try await blocked(h, bash("rm -rf /tmp/old")) == nil) // risky commands only ask when approvals are on
    }
}
