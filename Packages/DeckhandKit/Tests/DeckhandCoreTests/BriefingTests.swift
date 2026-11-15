import Foundation
import Testing
@testable import DeckhandCore

struct BriefingTests {
    let now = Date(timeIntervalSince1970: 1_794_812_400)

    /// A report as the server writes it: two security updates and one other, a restart, a certificate in 5 days,
    /// a disk at 91 % (88 % yesterday), a failed service, a failing watched cron job, failed logins and two fixes.
    func fixture(skip: String = "") -> String {
        let t = Int(now.timeIntervalSince1970)
        return """
        @@installed
        @@config BHOUR=07
        @@config BTZ='Europe/Berlin'
        @@config BTOPIC='https://ntfy.sh/deckhand-x'
        @@config BNAME='web '\\''one'\\'''
        @@config BQUIET=1
        @@config BFIXES=1
        @@config BMIN=30
        @@briefing \(t) web-1
        @@section updates
        @@pm apt
        @@kernel 6.8.0-40-generic
        @@reboot
        @@list
        openssl/noble-security 3.0.13-0ubuntu3.4 amd64 [upgradable from: 3.0.13-0ubuntu3.1]
        libssl3t64/noble-security 3.0.13-0ubuntu3.4 amd64 [upgradable from: 3.0.13-0ubuntu3.1]
        htop/noble-updates 3.3.0-4build2 amd64 [upgradable from: 3.3.0-4build1]
        @@section expiry
        @@installed
        @@domain shop.example.com
        @@domain blog.example.com
        @@status shop.example.com\t\(t + 5 * 86_400 + 600)\tLet's Encrypt\t-\t\(t)
        @@status blog.example.com\t\(t + 80 * 86_400)\tLet's Encrypt\t\(t + 200 * 86_400)\t\(t)
        @@section cron
        @@job 0 3 * * * /home/me/backup.sh # deckhand-cronwatch ab12
        @@watch ab12\t86400\tbackup.sh
        @@run ab12 \(t - 90_000) \(t - 89_990) 0
        @@run ab12 \(t - 3_600) \(t - 3_590) 2
        @@out ab12 tar: /srv/data: Cannot open: Permission denied
        @@section system
        @@disk / 91 2048000
        @@disk /boot 40 400000
        @@mem 62.0
        @@prevdisk / 88 3000000
        @@prevdisk /boot 40 400000
        @@memtrend 61.0 48.5
        @@failed nginx.service
        @@logins 312
        @@section fixes
        @@fix runs 12
        @@fix journal 1800 500
        \(skip)
        """
    }

    @Test func parsesTheReportAndConfig() throws {
        let s = Briefing.parse(fixture())
        #expect(s.installed)
        let c = try #require(s.config)
        #expect(c.hour == 7 && c.minute == 30)
        #expect(c.timeZone == "Europe/Berlin")
        #expect(c.name == "web 'one'")
        #expect(c.quiet && c.fixes)
        let r = try #require(s.report)
        #expect(r.host == "web-1")
        #expect(r.updates?.security.count == 2)
        #expect(r.updates?.rebootRequired == true)
        #expect(r.expiry?.entries.count == 2)
        #expect(r.disks.first { $0.mount == "/" }?.usedYesterday == 88)
        #expect(r.memoryTrend?.last == 61)
        #expect(r.failedUnits == ["nginx.service"])
        #expect(r.failedLogins == 312)
        #expect(r.fixes == [.oldRuns(count: 12), .journal(beforeMB: 1800, afterMB: 500)])
    }

    @Test func briefingTextMostUrgentFirst() throws {
        let r = try #require(Briefing.parse(fixture()).report)
        let items = Briefing.items(r, now: now)
        let titles = items.map(\.title)
        #expect(titles.contains("2 security updates"))
        #expect(titles.contains("Restart needed to finish updates"))
        #expect(titles.contains("Certificate for shop.example.com expires in 5 days"))
        #expect(!titles.contains { $0.contains("blog.example.com") })          // 80 days: not worth a line
        #expect(titles.contains("Disk / is 91% full"))
        #expect(items.first { $0.title == "Disk / is 91% full" }?.kind == .diskFull(mount: "/", used: 91, grewSinceYesterday: 3))
        #expect(titles.contains("Memory use went up from 48% to 61% on average"))
        #expect(titles.contains("1 service failed"))
        #expect(titles.contains("Cron job backup.sh failed"))
        #expect(items.first { $0.tool == .cron }?.detail == "tar: /srv/data: Cannot open: Permission denied")
        #expect(titles.contains("312 failed logins in 24 hours"))
        #expect(titles.contains("Removed 12 old task logs"))
        #expect(titles.contains("Shrank the system journal from 1800 MB to 500 MB"))
        // attention first, then info, then what was done
        let levels = items.map(\.level)
        #expect(levels == levels.sorted())
        #expect(items.first?.level == .attention)
        #expect(items.last?.level == .done)
    }

    @Test func quietDayHasNoAttention() {
        let t = Int(now.timeIntervalSince1970)
        let r = Briefing.parse("""
        @@briefing \(t) db-1
        @@section updates
        @@pm apt
        @@list
        htop/noble-updates 3.3.0-4build2 amd64 [upgradable from: 3.3.0-4build1]
        @@section system
        @@disk / 40 9000000
        @@mem 30.0
        @@logins -
        """).report!
        let items = Briefing.items(r, now: now)
        #expect(!items.contains { $0.level == .attention })
        #expect(r.failedLogins == nil)
        #expect(items.map(\.title) == ["1 other update"])
    }

    @Test func skippedFixesAreExplained() throws {
        let r = try #require(Briefing.parse(fixture(skip: "@@skipfix readonly\n@@skipfix nosudo journal 2200")).report)
        let titles = Briefing.items(r, now: now).map(\.title)
        #expect(titles.contains("No fixes: house rules are read-only"))
        #expect(titles.contains("The system journal uses 2200 MB; shrinking it needs sudo without a password"))
    }

    /// The push text is made on the server with awk; run that awk here on the same report.
    @Test func pushSummaryMatchesTheReport() throws {
        func summary(_ report: String) throws -> [String] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dh-brief-\(UUID().uuidString.prefix(6))")
            try report.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "summary() {\n\(Briefing.summaryAwk)\n}\nsummary '\(file.path)'"]
            let out = Pipe(); p.standardOutput = out
            try p.run(); p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").map(String.init)
        }
        // The fixture's dates are fixed in the past for the awk (it uses the real clock): shift them to now.
        let shift = Int(Date().timeIntervalSince1970) - Int(now.timeIntervalSince1970)
        let report = fixture().replacingOccurrences(of: "\(Int(now.timeIntervalSince1970) + 5 * 86_400 + 600)",
                                                    with: "\(Int(now.timeIntervalSince1970) + 5 * 86_400 + 600 + shift)")
        let s = try summary(report)
        #expect(s.first == "1")
        #expect(s.last == "2 security updates · restart needed · disk / 91% · 1 service failed · 1 cron job failing · 1 certificate or domain expiring · 1 other update · 2 small fixes done")
        let quiet = try summary("@@briefing 1 x\n@@section updates\n@@list\nhtop/noble-updates 3 amd64\n@@section system\n@@disk / 40 1\n")
        #expect(quiet == ["0", "All good · 1 update waiting"])
    }

    @Test func installWritesConfigAndHourlyCron() {
        let cmd = Briefing.installCommand(.init(hour: 6, minute: 45, timeZone: "Europe/Berlin", topic: "https://ntfy.sh/t", name: "web-1"))
        #expect(cmd.contains("45 * * * * $HOME/.deckhand/briefing/run.sh"))
        #expect(cmd.contains("BHOUR=06"))
        #expect(cmd.contains("BMIN=45"))
        #expect(cmd.contains("# deckhand-briefing"))
        #expect(Briefing.script.contains("TZ=\"$BTZ\" date +%H"))
    }
}
