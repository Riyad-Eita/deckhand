import Testing
@testable import DeckhandCore

struct SecurityAuditTests {
    let fresh = SecurityAudit.parse("""
    ssh.password=yes
    ssh.kbd=no
    ssh.root=yes
    ssh.maxauthtries=6
    ssh.x11=yes
    ssh.ports=22
    ssh.include=yes
    pm=apt
    firewall=ufw-inactive
    fail2ban=inactive
    updates=12
    updates.security=3
    updates.listage=1
    autoupdates=no
    public=22 80 443 5432
    nopasswd=
    emptypw=
    shellusers=root deploy
    worldwritable=/etc/app.conf
    reboot=yes
    timesync=yes
    """)

    @Test func freshServerScoresLowWithFixes() {
        let checks = SecurityAudit.checks(fresh, context: .init(loginUser: "deploy", usesKey: true))
        let byID = Dictionary(uniqueKeysWithValues: checks.map { ($0.id, $0) })
        #expect(byID["ssh.password"]?.level == .bad)
        #expect(byID["firewall"]?.level == .bad)
        #expect(byID["ports"]?.detail.contains("PostgreSQL (5432)") == true)
        #expect(byID["updates"]?.detail == "3 security updates waiting")
        #expect(checks.first?.level == .bad)
        #expect(SecurityAudit.score(checks) < 40)
        // The firewall keeps SSH and the public web ports open, but not the database.
        guard case .change(let ufw, true)? = byID["firewall"]?.fix else { Issue.record("no ufw fix"); return }
        #expect(ufw.apply.contains("ufw allow 22/tcp") && ufw.apply.contains("ufw allow 443/tcp"))
        #expect(!ufw.apply.contains("5432"))
        guard case .change(let ssh, true)? = byID["ssh.password"]?.fix else { Issue.record("no ssh fix"); return }
        #expect(ssh.apply.contains("'PasswordAuthentication no'") && ssh.apply.contains("'PermitRootLogin no'"))
    }

    @Test func passwordLoginsArentTurnedOffUnderAPasswordUser() {
        let checks = SecurityAudit.checks(fresh, context: .init(loginUser: "root", usesKey: false))
        let pw = checks.first { $0.id == "ssh.password" }!
        #expect(pw.fixBlocked != nil)
        guard case .change(let ssh, _)? = pw.fix else { Issue.record("no fix"); return }
        #expect(!ssh.apply.contains("PasswordAuthentication"))
        #expect(ssh.apply.contains("'PermitRootLogin prohibit-password'"))
    }

    @Test func hardenedServerScoresFull() {
        let good = SecurityAudit.parse("""
        ssh.password=no
        ssh.kbd=no
        ssh.root=no
        ssh.maxauthtries=3
        ssh.x11=no
        ssh.ports=40022
        pm=apt
        firewall=ufw
        fail2ban=active
        updates=0
        updates.security=0
        updates.listage=0
        autoupdates=yes
        public=40022 443
        shellusers=deploy
        reboot=no
        timesync=yes
        """)
        let checks = SecurityAudit.checks(good, context: .init(loginUser: "deploy", usesKey: true))
        #expect(checks.allSatisfy { $0.level == .good })
        #expect(SecurityAudit.score(checks) == 100)
    }
}
