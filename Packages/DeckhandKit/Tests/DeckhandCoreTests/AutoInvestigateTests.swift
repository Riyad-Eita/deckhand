import Foundation
import Testing
@testable import DeckhandCore

@Suite(.serialized)
struct AutoInvestigateTests {
    @Test func configIsClampedAndStoredWithTheEngineName() throws {
        let c = AutoInvestigate.Config(cli: .codex, diskPercent: 10, maxPerDay: 99, topic: "https://ntfy.sh/t", server: "S", name: "web-1")
        #expect(c.diskPercent == 50 && c.maxPerDay == 20)
        let j = try JSONValue.parse(c.json)
        #expect(j["engine"]?.stringValue == "Codex")
        #expect(j["cli"]?.stringValue == "codex")
        let back = try JSONDecoder().decode(AutoInvestigate.Config.self, from: Data(c.json.utf8))
        #expect(back == c)
    }

    @Test func parsesStatusNewestFirst() {
        let s = AutoInvestigate.parse("""
        @@installed
        @@config {"cli":"claudeCode","disk":true,"diskPercent":85,"engine":"Claude Code","maxPerDay":2,"name":"web","server":"X","services":true,"topic":"https://ntfy.sh/t","uptime":false}
        @@inv {"arg":"nginx.service","cause":"Typo in the config.","fix":"sudo -n systemctl restart nginx","fp":"0123456789ab","id":"i-20261115-070000","key":"service:nginx.service","kind":"service","risky":false,"run":"inv-20261115-070000","started":1794812400,"status":"proposed","title":"nginx.service failed","updated":1794812460}
        @@inv {"arg":"/","id":"i-20261114-070000","key":"disk:/","kind":"disk","percent":93,"started":1794726000,"status":"limited","title":"Disk / is 93% full"}
        """)
        #expect(s.installed && s.python)
        #expect(s.config?.diskPercent == 85 && s.config?.uptime == false)
        #expect(s.investigations.map(\.id) == ["i-20261115-070000", "i-20261114-070000"])
        #expect(s.investigations[0].status == .proposed && s.investigations[0].status.isOpen)
        #expect(s.investigations[1].percent == 93)
        #expect(s.startedToday(now: Date(timeIntervalSince1970: 1_794_812_500)) == 1)
    }

    @Test func commandsRefuseBadIDsAndCarryTheCronTag() {
        #expect(AutoInvestigate.applyCommand(id: "x; rm -rf ~", device: "me") == "echo '@@failed bad id'")
        #expect(AutoInvestigate.applyCommand(id: "i-20261115-070000", device: "Riad's iPhone").hasSuffix("'Riad'\\''s iPhone' app"))
        let c = AutoInvestigate.Config(cli: .claudeCode, topic: "", server: "", name: "x")
        #expect(AutoInvestigate.installCommand(c).contains("inv.py tick >/dev/null 2>&1 # deckhand-investigate"))
        #expect(AutoInvestigate.script.contains("RISKY = re.compile("))
        #expect(AutoInvestigate.launcher(c, access: .readOnly).contains("--permission-mode plan"))
        #expect(AutoInvestigate.launcher(c, access: .full).contains("finish \"$IID\" \"$c\" apply"))
    }

    // MARK: - The checker itself, with a fake Claude Code, systemctl and df in a temporary home

    final class Sandbox {
        let home: URL
        var bin: URL { home.appendingPathComponent(".local/bin") }
        var dir: URL { home.appendingPathComponent(".deckhand/investigate") }

        init(maxPerDay: Int = 3) throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("dh-inv-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".deckhand/investigate"), withIntermediateDirectories: true)
            let c = AutoInvestigate.Config(cli: .claudeCode, maxPerDay: maxPerDay, topic: "", server: "S", name: "test")
            try write(AutoInvestigate.script, to: dir.appendingPathComponent("inv.py"))
            try write(AutoInvestigate.launcher(c, access: .readOnly), to: dir.appendingPathComponent("start.sh"))
            try write(AutoInvestigate.launcher(c, access: .full), to: dir.appendingPathComponent("apply.sh"))
            try write(c.json, to: dir.appendingPathComponent("config.json"))
            try write("""
            #!/bin/sh
            case "$1" in
              --failed) cat "$HOME/failed" 2>/dev/null ;;
              is-failed) grep -q "^$3 " "$HOME/failed" 2>/dev/null ;;
              *) true ;;
            esac
            """, to: bin.appendingPathComponent("systemctl"), executable: true)
            try write("""
            #!/bin/sh
            echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
            echo "/dev/sda1 1000 400 600 40% /"
            [ -f "$HOME/diskfull" ] && echo "/dev/sdb1 1000 950 50 95% $HOME/data"
            true
            """, to: bin.appendingPathComponent("df"), executable: true)
            try write("""
            #!/usr/bin/env python3
            import json, os, sys
            home = os.environ["HOME"]
            open(home + "/claude-args", "a").write(" ".join(sys.argv[3:]) + "\\n")
            print(json.dumps({"type": "system", "subtype": "init", "session_id": "s-1"}))
            if "Run exactly these commands" in sys.argv[2]:
                open(home + "/failed", "w").write("")
                text = "nginx is running again."
            else:
                text = ("**Cause:** nginx.service stopped because its config has a typo.\\n\\nThe log shows it.\\n\\n"
                        "## Suggested fix\\n```sh\\n" + os.environ.get("FAKE_FIX", "sudo -n systemctl restart nginx") + "\\n```\\n")
            print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": text}))
            """, to: bin.appendingPathComponent("claude"), executable: true)
        }

        deinit { try? FileManager.default.removeItem(at: home) }

        func write(_ s: String, to url: URL, executable: Bool = false) throws {
            try s.write(to: url, atomically: true, encoding: .utf8)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }

        @discardableResult
        func run(_ command: String, env extra: [String: String] = [:]) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", command]
            p.environment = ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin", "LANG": "C.UTF-8"].merging(extra) { $1 }
            let out = Pipe(); p.standardOutput = out
            try p.run(); p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        /// Only the fake may answer: a real Claude Code on this machine must never be reached.
        var fakeWins: Bool {
            ((try? run("bash -lc 'command -v claude'")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == bin.appendingPathComponent("claude").path
        }

        func status() throws -> AutoInvestigate.Status { AutoInvestigate.parse(try run(AutoInvestigate.statusCommand)) }

        /// Waits until the newest investigation reaches `state`.
        func wait(for state: AutoInvestigate.State, timeout: TimeInterval = 20) throws -> AutoInvestigate.Investigation? {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if let i = try status().investigations.first, i.status == state { return i }
                Thread.sleep(forTimeInterval: 0.3)
            }
            return try status().investigations.first
        }
    }

    @Test func failedServiceIsInvestigatedReadOnlyAndTheApprovedFixApplied() throws {
        let box = try Sandbox()
        guard box.fakeWins else { return }
        try box.write("nginx.service loaded failed failed A web server\n", to: box.home.appendingPathComponent("failed"))
        try box.run("python3 ~/.deckhand/investigate/inv.py tick")
        let found = try #require(try box.wait(for: .proposed))
        #expect(found.kind == .service && found.arg == "nginx.service" && found.title == "nginx.service failed")
        #expect(found.cause == "nginx.service stopped because its config has a typo.")
        #expect(found.fix == "sudo -n systemctl restart nginx")
        #expect(found.risky == false && found.fp?.count == 12)
        // The run is an ordinary background task.
        #expect(try box.run("cat ~/.deckhand/runs/\(found.run ?? "-").meta").contains("\"title\": \"Investigate: nginx.service failed\""))

        // Still failing on the next minute: no second run for the same problem.
        try box.run("python3 ~/.deckhand/investigate/inv.py tick")
        #expect(try box.status().investigations.count == 1)

        #expect(try box.run(AutoInvestigate.applyCommand(id: found.id, device: "iPhone")).hasPrefix("@@applying inv-"))
        let fixed = try #require(try box.wait(for: .fixed))
        #expect(fixed.result == "nginx is running again." && fixed.who == "iPhone")
        let args = try box.run("cat ~/claude-args").split(separator: "\n")
        #expect(args.count == 2)
        #expect(args.first?.contains("--permission-mode plan") == true, "the investigation is read-only")
        #expect(args.last?.contains("--permission-mode bypassPermissions") == true, "only the approved fix may change things")
    }

    @Test func riskyFixNeedsTheAppAndHouseRulesStopFixes() throws {
        let box = try Sandbox()
        guard box.fakeWins else { return }
        try box.write("app.service loaded failed failed My app\n", to: box.home.appendingPathComponent("failed"))
        try box.run("python3 ~/.deckhand/investigate/inv.py tick", env: ["FAKE_FIX": "rm -rf /srv/app/cache && systemctl restart app"])
        let found = try #require(try box.wait(for: .proposed))
        #expect(found.risky == true)
        // A tap on the push (no "app") isn't enough for this one.
        #expect(try box.run("python3 ~/.deckhand/investigate/inv.py apply \(found.id) lockscreen").contains("@@needsapp"))
        #expect(try box.status().investigations.first?.status == .proposed)

        // Read-only house rules stop it even when approved in the app.
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".deckhand/rules"), withIntermediateDirectories: true)
        try box.write(HouseRules.hookScript, to: box.home.appendingPathComponent(".deckhand/rules/hook.py"))
        try box.write("{\"readOnly\": true}\n", to: box.home.appendingPathComponent(".deckhand/rules/rules.json"))
        #expect(try box.run(AutoInvestigate.applyCommand(id: found.id, device: "iPhone")).contains("@@blocked Read-only mode"))
        #expect(try box.status().investigations.first?.status == .blocked)
        #expect(try box.run("ls ~/.deckhand/runs | grep -c fix || true").trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }

    @Test func dailyLimitAndProblemsThatGoAway() throws {
        let box = try Sandbox(maxPerDay: 1)
        guard box.fakeWins else { return }
        try box.write("nginx.service loaded failed failed A web server\n", to: box.home.appendingPathComponent("failed"))
        try box.run("python3 ~/.deckhand/investigate/inv.py tick")
        let first = try #require(try box.wait(for: .proposed))
        // The service comes back by itself: the proposal is no longer needed.
        try box.write("", to: box.home.appendingPathComponent("failed"))
        try box.write("", to: box.home.appendingPathComponent("diskfull"))
        try box.run("python3 ~/.deckhand/investigate/inv.py tick")
        let s = try box.status()
        #expect(s.investigations.first { $0.id == first.id }?.status == .resolved)
        // The full disk would be the second run today: over the limit, so it is only noted.
        let limited = try #require(s.investigations.first { $0.kind == .disk })
        #expect(limited.status == .limited && limited.percent == 95)
        #expect(s.startedToday() == 1)
        #expect(try box.run("python3 ~/.deckhand/investigate/inv.py dismiss \(first.id) me").contains("@@state resolved"))
    }
}
