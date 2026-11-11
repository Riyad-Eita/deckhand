import Foundation
import Testing
@testable import DeckhandCore

struct TripwireTests {
    @Test func decoysAreFreshAndFake() {
        let a = Tripwire.decoys(home: "/home/me", user: "me"), b = Tripwire.decoys(home: "/home/me", user: "me")
        #expect(a.map(\.path) == ["/root/.aws/credentials", "/home/me/.env.production", "/home/me/backups/db-full-latest.sql", "/home/me/.ssh/id_rsa_old"])
        #expect(a[0].content != b[0].content)
        #expect(a[0].content.contains("aws_access_key_id = AKIA"))
        #expect(a[3].content.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
    }

    @Test func enableAndDisable() throws {
        let decoys = Tripwire.decoys(home: "/home/me", user: "me")
        let c = try #require(Tripwire.enable(topicURL: "https://ntfy.sh/x", decoys: decoys))
        #expect(c.files.contains("/etc/systemd/system/deckhand-tripwire.service"))
        #expect(c.apply.contains("chown 'me': '/home/me/.env.production'"))
        #expect(c.apply.contains("chmod 600 '/root/.aws/credentials'"))
        #expect(c.verify.contains("is-active"))
        #expect(Tripwire.enable(topicURL: "", decoys: decoys) == nil)
        let d = Tripwire.disable(decoys: decoys.map(\.path))
        #expect(d.apply.contains("systemctl disable --now deckhand-tripwire") && d.apply.contains("'/home/me/.ssh/id_rsa_old'"))
    }

    @Test func statusParses() {
        let s = Tripwire.parse("@@active\n@@decoy /root/.aws/credentials \tCloud keys (root)\n@@hit 2026-11-11 18:00:01 CET /root/.aws/credentials opened by root (pid 42: cat /root/.aws/credentials)\n")
        #expect(s.active && s.decoys.first?.title == "Cloud keys (root)" && s.hits.count == 1)
    }

    @Test func watcherScriptCompiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "tw-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Tripwire.watcherScript.write(toFile: dir + "/w.py", atomically: true, encoding: .utf8)
        let r = try await LocalShell().run("python3 -m py_compile '\(dir)/w.py' && echo ok", timeout: .seconds(20))
        #expect(r.stdout.contains("ok"), "\(r.stderr)")
    }
}
