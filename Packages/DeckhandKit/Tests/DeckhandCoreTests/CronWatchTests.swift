import Foundation
import Testing
@testable import DeckhandCore

struct CronWatchTests {
    @Test func linesAndSchedules() {
        #expect(CronWatch.parseLine("*/5 * * * * /usr/bin/backup --all")! == ("*/5 * * * *", "/usr/bin/backup --all"))
        #expect(CronWatch.parseLine("@daily certbot renew")! == ("@daily", "certbot renew"))
        #expect(CronWatch.parseLine("MAILTO=me@example.com") == nil && CronWatch.parseLine("# 0 3 * * * x") == nil)
        #expect(CronWatch.interval("*/5 * * * *") == 300)
        #expect(CronWatch.interval("17 * * * *") == 3_600)
        #expect(CronWatch.interval("30 3 * * *") == 86_400)
        #expect(CronWatch.interval("0 4 * * 1") == 604_800)
        #expect(CronWatch.interval("0 */6 * * *") == 21_600)
        #expect(CronWatch.interval("@reboot") == nil)
        #expect(CronWatch.describe("30 3 * * *") == "Every day at 03:30")
        #expect(CronWatch.describe("0 4 * * 1,4") == "Mon, Thu at 04:00")
        #expect(CronWatch.describe("*/10 * * * *") == "Every 10 minutes")
    }

    @Test func watchRefusesStdinPercent() {
        #expect(CronWatch.watchCommand(line: "0 3 * * * mail -s x me % body", name: "x", topic: "") == "echo '@@failed uses %'")
        let ok = CronWatch.watchCommand(line: #"0 3 * * * tar czf /b/$(date +\%F).tgz /srv"#, name: "Backup", topic: "", id: "abc123")
        #expect(ok.contains("tar czf /b/$(date +%F).tgz /srv") && ok.contains("wrap.sh abc123 # deckhand-cronwatch abc123"))
        #expect(CronWatch.unwatchCommand(id: "../") == "echo '@@failed unknown'")
    }

    @Test func parsesStatus() {
        let s = CronWatch.parseStatus("""
        @@job 0 3 * * * $HOME/.deckhand/cronwatch/wrap.sh ab12 # deckhand-cronwatch ab12
        @@job */5 * * * * /usr/bin/true
        @@watch ab12\t86400\tBackup
        @@run ab12 1800000000 1800000042 0
        @@run ab12 1800086400 1800086401 3
        @@out ab12 tar: /b: No space left on device
        @@missing ab12 1800200000
        @@orig ab12 0 3 * * * /usr/local/bin/backup.sh
        """)
        #expect(s.jobs.count == 2 && s.jobs[0].watchID == "ab12" && s.jobs[1].watchID == nil)
        let w = try! #require(s.watches["ab12"])
        #expect(w.name == "Backup" && w.runs.count == 2 && w.last?.exitCode == 3 && w.runs[0].seconds == 42)
        #expect(w.output == ["tar: /b: No space left on device"] && w.missingSince != nil)
        #expect(w.originalCommand == "/usr/local/bin/backup.sh")
    }
}
