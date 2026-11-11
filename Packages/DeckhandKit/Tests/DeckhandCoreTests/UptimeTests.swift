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
        _ = try await shell.run("cd '\(home)/site' && (python3 -m http.server \(web) --bind 127.0.0.1 >/dev/null 2>&1 &) ; (python3 '\(home)/fake.py' \(hook) '\(home)/pushes' >/dev/null 2>&1 &) ; sleep 1.5", timeout: .seconds(10))
        defer { Task { _ = try? await shell.run("pkill -f 'http.server \(web) --bind'; pkill -f 'fake.py \(hook)'", timeout: .seconds(5)) } }
        _ = try await shell.run("HOME='\(home)' FORCE=1 sh '\(d)/run.sh'", timeout: .seconds(30))
        let ok = try String(contentsOfFile: d + "/ok1.log", encoding: .utf8)
        let bad = try String(contentsOfFile: d + "/bad1.log", encoding: .utf8)
        #expect(ok.split(separator: " ")[1] == "200" && ok.hasSuffix(" 1\n"))
        #expect(bad.hasSuffix(" 0\n"))
        for _ in 0..<30 where !FileManager.default.fileExists(atPath: home + "/pushes") { try await Task.sleep(for: .milliseconds(100)) }
        #expect(try String(contentsOfFile: home + "/pushes", encoding: .utf8) == "Down: Site text (200) | deckhand://uptime/AB-12/bad1\n")
    }
}
