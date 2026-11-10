import Testing
@testable import DeckhandCore

@Suite struct ServicesTests {
    @Test func parsesJSONFailedFirst() {
        let json = #"[{"unit":"nginx.service","load":"loaded","active":"active","sub":"running","description":"nginx"},{"unit":"fail2ban.service","load":"loaded","active":"failed","sub":"failed","description":"Fail2Ban Service"},{"unit":"auditd.service","load":"not-found","active":"inactive","sub":"dead","description":"auditd.service"},{"unit":"apt-daily.service","load":"loaded","active":"inactive","sub":"dead","description":"Daily apt"}]"#
        let u = Services.parse(json)
        #expect(u.map(\.name) == ["fail2ban.service", "nginx.service", "apt-daily.service"])
        #expect(u[0].isFailed && u[1].isRunning)
        #expect(u[1].shortName == "nginx")
    }

    @Test func parsesPlainTable() {
        let plain = """
        cron.service       loaded active   running Regular background program processing daemon
        exim4.service      loaded failed   failed  LSB: exim Mail Transport Agent
        """
        let u = Services.parse(plain)
        #expect(u.map(\.name) == ["exim4.service", "cron.service"])
        #expect(u[1].description == "Regular background program processing daemon")
    }

    @Test func sudoPasswordBecomesTerminalCommand() {
        let r = CommandResult(stdout: "", stderr: "sudo: a password is required\n", exitCode: 1)
        #expect(throws: ServiceError.needsPassword(command: "sudo systemctl restart 'nginx.service' && systemctl status --no-pager 'nginx.service' | head -5")) {
            try Services.check(r, action: .restart, unit: "nginx.service")
        }
        #expect(throws: Never.self) { try Services.check(CommandResult(stdout: ""), action: .start, unit: "x") }
    }
}
