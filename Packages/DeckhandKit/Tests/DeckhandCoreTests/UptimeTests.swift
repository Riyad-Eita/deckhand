import Foundation
import Testing
@testable import DeckhandCore

@Suite(.serialized) struct UptimeTests {
    @Test func parsesStatus() {
        let s = Uptime.parse("""
        @@cron yes
        @@installed
        @@check a1b2c3d4\tShop\thttps://shop.example.com\t5\t200-399\tAdd to cart
        @@r 1794300000 200 182 1
        @@r 1794300300 503 25 0
        @@check e5f6a7b8\tAPI\thttps://api.example.com/health\t1\t200\t
        """)
        #expect(s.cron && s.installed)
        #expect(s.checks.map(\.name) == ["Shop", "API"])
        #expect(s.checks[0].keyword == "Add to cart" && s.checks[0].every == 5)
        #expect(s.checks[0].isUp == false && s.checks[0].uptime == 0.5)
        #expect(s.checks[1].results.isEmpty && s.checks[1].isUp == nil)
    }

    @Test func validates() {
        #expect(Uptime.isValid(.init(name: "Shop", url: "https://shop.example.com", expect: "200-399")))
        #expect(!Uptime.isValid(.init(name: "x", url: "ftp://x", expect: "200")))
        #expect(!Uptime.isValid(.init(name: "x", url: "https://x.example.com", expect: "2xx")))
    }

    /// The runner checks a local web server, records results and pushes when a check goes down.
    @Test func runnerChecksAndPushes() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "up-\(UUID().uuidString.prefix(6))").path
        let d = home + "/.deckhand/uptime"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/site", withIntermediateDirectories: true)
        try "hello world".write(toFile: home + "/site/index.html", atomically: true, encoding: .utf8)
        try Uptime.runner.write(toFile: d + "/run.sh", atomically: true, encoding: .utf8)
        let web = Int.random(in: 42000...45000), hook = web + 1
        // A fake ntfy: records POST bodies.
        let fake = """
        import http.server, sys
        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get('Content-Length', 0)); open(sys.argv[2], 'a').write(self.rfile.read(n).decode() + ' | ' + self.headers.get('Click', '-') + '\\n')
                self.send_response(200); self.end_headers()
            def log_message(self, *a): pass
        http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
        """
        try fake.write(toFile: home + "/fake.py", atomically: true, encoding: .utf8)
        try "TOPIC='http://127.0.0.1:\(hook)/t'\nSERVER=AB-12\n".write(toFile: d + "/config", atomically: true, encoding: .utf8)
        try "ok1\tSite\thttp://127.0.0.1:\(web)/index.html\t1\t200\thello\nbad1\tSite text\thttp://127.0.0.1:\(web)/index.html\t1\t200\tmissing\n"
            .write(toFile: d + "/checks.tsv", atomically: true, encoding: .utf8)
        let shell = LocalShell()
        _ = try await shell.run("cd '\(home)/site' && (python3 -m http.server \(web) --bind 127.0.0.1 >/dev/null 2>&1 &) ; (python3 '\(home)/fake.py' \(hook) '\(home)/pushes' >/dev/null 2>&1 &) ; \(waitForPorts(web, hook))", timeout: .seconds(30))
        defer { Task { _ = try? await shell.run("pkill -f 'http.server \(web) --bind'; pkill -f 'fake.py \(hook)'", timeout: .seconds(5)) } }
        _ = try await shell.run("HOME='\(home)' FORCE=1 sh '\(d)/run.sh'", timeout: .seconds(30))
        let ok = try String(contentsOfFile: d + "/ok1.log", encoding: .utf8)
        let bad = try String(contentsOfFile: d + "/bad1.log", encoding: .utf8)
        #expect(ok.split(separator: " ")[1] == "200" && ok.hasSuffix(" 1\n"))
        #expect(bad.hasSuffix(" 0\n"))
        for _ in 0..<30 where !FileManager.default.fileExists(atPath: home + "/pushes") { try await Task.sleep(for: .milliseconds(100)) }
        #expect(try String(contentsOfFile: home + "/pushes", encoding: .utf8) == "Down: Site text (200) | deckhand://uptime/AB-12/bad1\n")
    }

    @Test func remedyFixesAndReports() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "fix-\(UUID().uuidString.prefix(6))").path
        let d = home + "/.deckhand/uptime"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/site", withIntermediateDirectories: true)
        try "broken".write(toFile: home + "/site/index.html", atomically: true, encoding: .utf8)
        try Uptime.runner.write(toFile: d + "/run.sh", atomically: true, encoding: .utf8)
        let web = Int.random(in: 45001...47000), hook = web + 1
        let fake = """
        import http.server, sys
        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get('Content-Length', 0)); open(sys.argv[2], 'a').write(self.rfile.read(n).decode() + ' | ' + self.headers.get('Priority', '-') + '\\n')
                self.send_response(200); self.end_headers()
            def log_message(self, *a): pass
        http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
        """
        try fake.write(toFile: home + "/fake.py", atomically: true, encoding: .utf8)
        try "TOPIC='http://127.0.0.1:\(hook)/t'\n".write(toFile: d + "/config", atomically: true, encoding: .utf8)
        let url = "http://127.0.0.1:\(web)/index.html"
        try "heal\tShop\t\(url)\t1\t200\thealthy\nnofix\tAPI\t\(url)\t1\t200\tnever-there\n".write(toFile: d + "/checks.tsv", atomically: true, encoding: .utf8)
        let shell = LocalShell()
        let heal = Uptime.setRemedyCommand(checkID: "heal", remedy: .init(commands: "echo healthy > \"$HOME/site/index.html\"\nsudo systemctl restart shop || true", maxPerHour: 2))
        let fail = Uptime.setRemedyCommand(checkID: "nofix", remedy: .init(commands: "exit 3", maxPerHour: 1))
        _ = try await shell.run("HOME='\(home)' sh -c \(ShellQuote.quote(heal + "\n" + fail))", timeout: .seconds(10))
        #expect(try String(contentsOfFile: d + "/heal.fix", encoding: .utf8).contains("sudo -n systemctl restart shop"))
        _ = try await shell.run("cd '\(home)/site' && (python3 -m http.server \(web) --bind 127.0.0.1 >/dev/null 2>&1 &) ; (python3 '\(home)/fake.py' \(hook) '\(home)/pushes' >/dev/null 2>&1 &) ; \(waitForPorts(web, hook))", timeout: .seconds(30))
        defer { Task { _ = try? await shell.run("pkill -f 'http.server \(web) --bind'; pkill -f 'fake.py \(hook)'", timeout: .seconds(5)) } }
        // Two runs: the second may not run the failing fix again (limit 1 per hour).
        _ = try await shell.run("HOME='\(home)' FORCE=1 FIXWAIT=0 sh '\(d)/run.sh'; HOME='\(home)' FORCE=1 FIXWAIT=0 sh '\(d)/run.sh'", timeout: .seconds(60))
        for _ in 0..<30 where (try? String(contentsOfFile: home + "/pushes", encoding: .utf8))?.split(separator: "\n").count ?? 0 < 2 {
            try await Task.sleep(for: .milliseconds(100))
        }
        let pushes = try String(contentsOfFile: home + "/pushes", encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(pushes.contains("Fixed automatically: Shop (200) | default"))
        #expect(pushes.contains("Down: API (200). The automatic fix didn't help. | urgent"))
        #expect(pushes.count == 2)
        let status = Uptime.parse(try await shell.run("HOME='\(home)' sh -c \(ShellQuote.quote(Uptime.statusCommand))", timeout: .seconds(10)).stdout)
        let shop = try #require(status.checks.first { $0.id == "heal" })
        #expect(shop.isUp == true)
        #expect(shop.remedy?.maxPerHour == 2)
        #expect(shop.remedy?.runs.map(\.fixed) == [true])
        #expect(shop.remedy?.commands.hasPrefix("echo healthy") == true)
        let api = try #require(status.checks.first { $0.id == "nofix" })
        #expect(api.remedy?.runs.count == 1)
        #expect(api.remedy?.runs.first?.exitCode == 3)
        _ = try await shell.run("rm -rf '\(home)'", timeout: .seconds(10))
    }
}
