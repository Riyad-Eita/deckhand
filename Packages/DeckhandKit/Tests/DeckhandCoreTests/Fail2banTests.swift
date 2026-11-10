import Testing
@testable import DeckhandCore

struct Fail2banTests {
    @Test func parsesJailsAndBans() {
        let s = Fail2ban.parse("""
        @@jail sshd
        Status for the jail: sshd
        |- Filter
        |  |- Currently failed:\t3
        |  |- Total failed:\t412
        |  `- Journal matches:\t_SYSTEMD_UNIT=sshd.service + _COMM=sshd
        `- Actions
           |- Currently banned:\t2
           |- Total banned:\t57
           `- Banned IP list:\t203.0.113.9 198.51.100.7
        @@jail nginx-botsearch
        Status for the jail: nginx-botsearch
        |- Filter
        |  |- Currently failed:\t0
        |  |- Total failed:\t0
        `- Actions
           |- Currently banned:\t0
           |- Total banned:\t0
           `- Banned IP list:\t
        @@ignore 127.0.0.1/8 ::1 192.0.2.10
        """)
        #expect(s.installed && s.running)
        #expect(s.jails.map(\.name) == ["sshd", "nginx-botsearch"])
        #expect(s.jails[0].banned == ["203.0.113.9", "198.51.100.7"])
        #expect(s.jails[0].totalFailed == 412 && s.jails[0].totalBanned == 57)
        #expect(s.jails[0].reason == "Failed SSH logins")
        #expect(s.jails[1].banned.isEmpty)
        #expect(s.ignored == ["127.0.0.1/8", "::1", "192.0.2.10"])
        #expect(Fail2ban.parse("@@notinstalled").installed == false)
    }

    @Test func unbanAndAllowList() {
        #expect(Fail2ban.unbanScript("203.0.113.9", jail: "sshd") == "fail2ban-client set 'sshd' unbanip '203.0.113.9' && echo '@@done'")
        #expect(Fail2ban.unbanScript("1.2.3.4; rm -rf /", jail: "sshd") == nil)
        let allow = Fail2ban.allowList(["192.0.2.10"])!
        #expect(allow.apply.contains("'ignoreip = 127.0.0.1/8 ::1 192.0.2.10'"))
        #expect(allow.reload.contains("fail2ban-client unban '192.0.2.10'"))
        #expect(Fail2ban.allowList(["not an ip"]) == nil)
    }
}
