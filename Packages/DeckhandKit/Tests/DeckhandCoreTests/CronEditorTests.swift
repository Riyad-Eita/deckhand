import Foundation
import Testing
@testable import DeckhandCore

struct CronEditorTests {
    @Test func scheduleBothWays() {
        var s = CronEditor.Schedule()
        s.frequency = .weekly; s.weekdays = [1, 4]; s.hour = 3; s.minute = 0
        #expect(s.cron == "0 3 * * 1,4" && s.description == "Mon, Thu at 03:00")
        for expr in ["*/15 * * * *", "7 * * * *", "30 2 * * *", "0 3 * * 1,4", "45 23 15 * *"] {
            #expect(CronEditor.Schedule.from(expr).cron == expr, "\(expr)")
        }
        #expect(CronEditor.Schedule.from("0 3 * * 7").weekdays == [0])
        let odd = CronEditor.Schedule.from("0 9-17 * * 1-5")
        #expect(odd.frequency == .custom && odd.cron == "0 9-17 * * 1-5")
        #expect(CronEditor.isValidExpression("@daily") && CronEditor.isValidExpression("*/5 * * * *"))
        #expect(!CronEditor.isValidExpression("0 3 * *") && !CronEditor.isValidExpression("0 3 * * *; rm"))
        #expect(CronEditor.line(schedule: "0 3 * * *", command: "tar czf /b/$(date +%F).tgz /srv") == #"0 3 * * * tar czf /b/$(date +\%F).tgz /srv"#)
    }

    @Test func timers() {
        let out = """
        @@json [{"next":1794505140000000,"last":1794503351399588,"unit":"apt-daily.timer"},{"next":0,"last":1794400000000000,"unit":"certbot.timer"},{"next":1794600000000000,"last":0,"unit":"fresh.timer"}]
        @@timer apt-daily.timer\tDaily apt download activities\t*-*-* 6,18:00:00\tapt-daily.service\tsuccess\t0
        @@timer certbot.timer\tRun certbot twice daily\t*-*-* 00,12:00:00\tcertbot.service\texit-code\t1
        @@timer fresh.timer\tNever ran\t\tfresh.service\tsuccess\t0
        """
        let t = CronEditor.parseTimers(out)
        #expect(t.map(\.unit) == ["apt-daily.timer", "fresh.timer", "certbot.timer"])
        #expect(t[0].ok == true && t[0].calendar == "*-*-* 6,18:00:00" && t[0].last != nil)
        #expect(t[2].ok == false && t[2].exitStatus == 1 && t[2].next == nil)
        #expect(t[1].ok == nil)
    }
}
