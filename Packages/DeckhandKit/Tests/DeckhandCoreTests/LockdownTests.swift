import Foundation
import Testing
@testable import DeckhandCore

struct LockdownTests {
    @Test func changeContainsEveryChosenStep() {
        let plan = Lockdown.Plan(myAddress: "198.51.100.7", sshPorts: [22, 2200], stopServices: ["nginx.service", "bad;rm -rf /"])
        let c = Lockdown.change(plan, id: "20261111-170000-lockdown", root: "/tmp/dh")
        #expect(c.guardSeconds == SSHPort.guardSeconds)
        #expect(c.files.contains("/etc/ssh/sshd_config.d/00-deckhand-lockdown.conf"))
        #expect(c.apply.contains("@@evidence"))
        #expect(c.apply.contains("D='/tmp/dh/20261111-170000-lockdown-evidence'"))
        #expect(c.apply.contains("'PasswordAuthentication no'"))
        #expect(c.apply.contains("ufw insert 1 allow from 198.51.100.7 to any port 22 proto tcp"))
        #expect(c.apply.contains("ufw insert 2 deny 2200/tcp"))
        #expect(c.apply.contains("systemctl stop 'nginx.service'"))
        #expect(!c.apply.contains("bad;rm"))
        #expect(c.verify.contains("kill -HUP") && c.verify.contains("ended.txt"))
        #expect(c.validate == "sshd -t")
    }

    @Test func skipsWhatWasNotChosen() {
        let plan = Lockdown.Plan(myAddress: "2001:db8::1", onlyMyAddress: true, passwordsOff: false, endOtherSessions: false)
        #expect(!plan.canRestrict)
        let c = Lockdown.change(plan, id: "x")
        #expect(!c.apply.contains("ufw insert") && !c.apply.contains("PasswordAuthentication"))
        #expect(c.verify == "true")
    }

    @Test func allClearRollsBackAndRestarts() {
        let s = Lockdown.allClearScript(id: "abc", root: "/tmp/dh")
        #expect(s.hasPrefix("bash '/tmp/dh/abc/rollback.sh' || exit 1"))
        #expect(s.contains("systemctl start \"$u\""))
    }

    @Test func summaryParses() {
        let s = Lockdown.parseSummary("@@files 10\n@@ended 2\n@@stopped nginx.service\n@@keys 3\n@@changed 41\n")
        #expect(s == .init(evidenceFiles: 10, endedSessions: 2, authorizedKeys: 3, changedFiles: 41, stopped: ["nginx.service"]))
    }

    @Test func evidenceRunsLocally() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ev-\(UUID().uuidString.prefix(6))").path
        let r = try await LocalShell().run(Lockdown.evidenceScript(dir), timeout: .seconds(120))
        #expect(r.stdout.contains("@@evidence \(dir)"))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
        #expect(files.contains("processes.txt") && files.contains("connections.txt") && files.contains("changed-files.txt"))
        _ = try await LocalShell().run("rm -rf '\(dir)'", timeout: .seconds(10))
    }
}
