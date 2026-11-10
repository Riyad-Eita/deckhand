import Foundation
import Testing
@testable import DeckhandCore

@Suite(.serialized) struct LoginAlertsTests {
    @Test func parsesStatusAndLogins() {
        let s = LoginAlerts.parse("""
        @@enabled
        @@TOPIC='https://ntfy.sh/deckhand-abc'
        @@TRUSTED='192.0.2.10 198.51.100.1'
        @@logins
        2026-11-10T16:20:01+0100 web-1 sshd[123]: Accepted publickey for deploy from 203.0.113.9 port 50122 ssh2: ED25519 SHA256:abc
        Nov 10 16:25:42 web-1 sshd[456]: Accepted password for root from 2001:db8::7 port 4022 ssh2
        """)
        #expect(s.enabled)
        #expect(s.topicURL == "https://ntfy.sh/deckhand-abc")
        #expect(s.trusted == ["192.0.2.10", "198.51.100.1"])
        #expect(s.logins.map(\.address) == ["2001:db8::7", "203.0.113.9"])
        #expect(s.logins[1].date == "2026-11-10 16:20" && s.logins[1].user == "deploy" && s.logins[1].method == "publickey")
        #expect(s.logins[0].date == "Nov 10 16:25")
    }

    @Test func enableValidatesInput() {
        #expect(LoginAlerts.enable(topicURL: "https://ntfy.sh/x'; rm -rf /", trusted: []) == nil)
        let c = LoginAlerts.enable(topicURL: "https://ntfy.sh/deckhand-abc", trusted: ["192.0.2.10", "nope; reboot"])!
        #expect(c.apply.contains("session optional pam_exec.so quiet /usr/local/bin/deckhand-login-alert"))
        #expect(!c.apply.contains("reboot"))
        #expect(c.guardSeconds != nil)
    }

    /// The hook alerts for unknown addresses and stays quiet for trusted ones.
    @Test func hookAlertsOnlyForUntrustedAddresses() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "la-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: dir + "/bin", withIntermediateDirectories: true)
        try "#!/bin/sh\necho \"$@\" >> \(dir)/curl.log\necho '{\"country\":\"Testland\"}'\n".write(toFile: dir + "/bin/curl", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir + "/bin/curl")
        let conf = "TOPIC='https://ntfy.example.com/t'\nTRUSTED='192.0.2.10'\n"
        try conf.write(toFile: dir + "/conf", atomically: true, encoding: .utf8)
        let hook = LoginAlerts.hookScript.replacingOccurrences(of: "/etc/deckhand/login-alert.conf", with: dir + "/conf")
        try hook.write(toFile: dir + "/hook", atomically: true, encoding: .utf8)
        func login(_ ip: String) async throws {
            _ = try await LocalShell().run("PATH=\(dir)/bin:/usr/bin:/bin PAM_TYPE=open_session PAM_USER=deploy PAM_RHOST=\(ip) /bin/sh \(dir)/hook", timeout: .seconds(10))
            try await Task.sleep(for: .milliseconds(600))
        }
        try await login("192.0.2.10")
        #expect(!FileManager.default.fileExists(atPath: dir + "/curl.log"))
        try await login("203.0.113.9")
        let log = try String(contentsOfFile: dir + "/curl.log", encoding: .utf8)
        #expect(log.contains("deploy from 203.0.113.9 (Testland)"))
        #expect(log.contains("https://ntfy.example.com/t"))
    }
}
