import Foundation
import Testing
@testable import DeckhandCore

@Suite struct HardeningProfilesTests {
    typealias P = HardeningPlan
    let key = SecurityAudit.Context(loginUser: "deploy", usesKey: true)

    func facts(_ extra: String = "") -> SecurityAudit.Facts {
        SecurityAudit.parse("""
        ssh.password=yes
        ssh.kbd=no
        ssh.root=yes
        ssh.maxauthtries=6
        ssh.ports=22
        ssh.include=yes
        pm=apt
        firewall=none
        fail2ban=inactive
        autoupdates=no
        public=22 80 443 5432 8080
        \(extra)
        """)
    }

    @Test func webServerOpensWebPortsAndClosesTheRest() {
        let plan = P.plan(.webServer, facts: facts(), context: key)
        #expect(plan.rules == [.init(port: 22), .init(port: 80), .init(port: 443)])
        #expect(plan.closes == [5432, 8080])
        #expect(plan.changes.map(\.id) == ["firewall", "ssh", "fail2ban", "autoupdates"])
        let fw = plan.items.first { $0.id == "firewall" }!
        #expect(fw.detail.contains("22, 80, 443") && fw.detail.contains("5432, 8080"))
        guard case .change(let change, let guarded) = fw.state else { Issue.record("no change"); return }
        #expect(guarded)
        #expect(change.apply.contains("ufw --force reset"))
        #expect(change.apply.contains("ufw allow 443/tcp"))
        #expect(!change.apply.contains("5432"))
        #expect(change.guardSeconds != nil)
    }

    @Test func databaseOpensItsPortOnlyForNamedClients() {
        let plan = P.plan(.database, facts: facts(), context: key, databaseClients: ["10.0.0.5", "203.0.113.0/24", "not-an-ip"])
        #expect(plan.rules.contains(.init(port: 5432, source: "10.0.0.5")))
        #expect(plan.rules.contains(.init(port: 5432, source: "203.0.113.0/24")))
        #expect(!plan.rules.contains { $0.source == "not-an-ip" })
        #expect(!plan.rules.contains(.init(port: 80)))
        #expect(plan.closes == [80, 443, 8080])
        guard case .change(let change, _) = plan.items[0].state else { Issue.record("no change"); return }
        #expect(change.apply.contains("ufw allow from 10.0.0.5 to any port 5432 proto tcp"))

        let alone = P.plan(.database, facts: facts(), context: key)
        #expect(alone.closes.contains(5432))
        #expect(alone.warnings.contains { $0.contains("No app servers") })
    }

    @Test func homeLabKeepsServicesForTheHomeNetwork() {
        let plan = P.plan(.homeLab, facts: facts(), context: key)
        #expect(plan.rules.contains(.init(port: 22)))
        #expect(plan.rules.contains(.init(port: 8080, source: "192.168.0.0/16")))
        #expect(plan.rules.contains(.init(port: 8080, source: "100.64.0.0/10")))
        #expect(!plan.rules.contains(.init(port: 8080)))
        #expect(plan.closes.isEmpty)
        #expect(plan.items[0].detail.contains("Limited: 80, 443, 5432, 8080"))
    }

    @Test func alreadyFineAndNotPossible() {
        let hardened = facts("""
        ssh.password=no
        ssh.root=prohibit-password
        ssh.maxauthtries=3
        fail2ban=active
        autoupdates=yes
        """)
        let plan = P.plan(.webServer, facts: hardened, context: key)
        #expect(plan.changes.map(\.id) == ["firewall"])

        let passwordLogin = P.plan(.webServer, facts: facts(), context: .init(loginUser: "deploy", usesKey: false))
        guard case .notPossible = passwordLogin.items.first(where: { $0.id == "ssh" })!.state else { Issue.record("ssh should be blocked"); return }

        let firewalld = P.plan(.webServer, facts: facts("firewall=firewalld\npm=dnf"), context: key)
        guard case .notPossible = firewalld.items[0].state else { Issue.record("firewalld"); return }
        let docker = P.plan(.webServer, facts: facts("dockerpublic=app:8080"), context: key)
        #expect(docker.warnings.contains { $0.contains("app:8080") })
    }

    @Test func validSources() {
        #expect(P.isValidSource("10.0.0.5"))
        #expect(P.isValidSource("192.168.1.0/24"))
        #expect(!P.isValidSource("10.0.0.256"))
        #expect(!P.isValidSource("10.0.0.5/33"))
        #expect(!P.isValidSource("10.0.0"))
        #expect(!P.isValidSource("010.0.0.5"))
        #expect(!P.isValidSource("10.0.0.5; rm -rf /"))
    }
}
