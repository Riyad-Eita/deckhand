import Foundation
import Testing
@testable import DeckhandCore

@Suite struct PlanUsageTests {
    let now = Date(timeIntervalSince1970: 1_763_100_000)   // 2025-11-14 06:00 UTC

    @Test func codexWindows() throws {
        let reset5h = Int(now.timeIntervalSince1970) + 3600, resetWeek = Int(now.timeIntervalSince1970) + 3 * 86400
        let line = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":86.5,"window_minutes":300,"resets_at":\#(reset5h)},"secondary":{"used_percent":40.0,"window_minutes":10080,"resets_at":\#(resetWeek)},"plan_type":"plus"}}}"#
        let usage = try #require(PlanUsage.parse("@@codex\t\(Int(now.timeIntervalSince1970) - 60)\t\(line)", now: now).first)
        #expect(usage.cli == .codex)
        #expect(usage.windows.map(\.name) == ["5-hour", "Weekly"])
        #expect(usage.windows[0].usedPercent == 86.5)
        #expect(usage.windows[0].resetsAt == Date(timeIntervalSince1970: TimeInterval(reset5h)))
        let warn = try #require(PlanUsage.warning(usage, now: now))
        #expect(warn.text.hasPrefix("87 % of the 5-hour limit used."))
        #expect(warn.resetsAt == Date(timeIntervalSince1970: TimeInterval(reset5h)))

        // Once the window has reset, it counts as unused — no warning.
        let later = now.addingTimeInterval(7200)
        let reset = try #require(PlanUsage.parse("@@codex\t\(Int(now.timeIntervalSince1970))\t\(line)", now: later).first)
        #expect(reset.windows[0].usedPercent == 0)
        #expect(PlanUsage.warning(reset, now: later) == nil)
    }

    @Test func claudeLimitMessage() throws {
        let seen = Date(timeIntervalSince1970: 1_763_096_400)   // 05:00 UTC = 06:00 Berlin
        let msg = "You've hit your 5-hour limit · resets 9:30am (Europe/Berlin)"
        let usage = try #require(PlanUsage.parse("@@claude\t\(Int(seen.timeIntervalSince1970))\t\(msg)", now: now).first)
        #expect(usage.cli == .claudeCode)
        var berlin = Calendar(identifier: .gregorian); berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let c = berlin.dateComponents([.hour, .minute], from: try #require(usage.limitResets))
        #expect(c.hour == 9 && c.minute == 30)
        #expect(PlanUsage.warning(usage, now: now)?.text.contains("hit its usage limit") == true)
        // A limit that has reset is not shown.
        #expect(PlanUsage.parse("@@claude\t\(Int(seen.timeIntervalSince1970))\t\(msg)", now: now.addingTimeInterval(6 * 3600)).isEmpty)
    }

    @Test func resetTimes() throws {
        let after = Date(timeIntervalSince1970: 1_763_096_400)
        let weekly = try #require(PlanUsage.resetTime(in: "You've hit your weekly limit · resets Nov 17, 3pm (Europe/Berlin)", after: after))
        var berlin = Calendar(identifier: .gregorian); berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let c = berlin.dateComponents([.month, .day, .hour], from: weekly)
        #expect(c.month == 11 && c.day == 17 && c.hour == 15)
        let noon = try #require(PlanUsage.resetTime(in: "resets 12am (UTC/UTC)", after: after) ?? PlanUsage.resetTime(in: "resets 12am", after: after))
        #expect(noon > after)
        #expect(PlanUsage.resetTime(in: "no time here", after: after) == nil)
    }

    @Test func startDelayWaitsOnTheServer() {
        let cmd = LimitAwareRun.command(.codex, prompt: "big job", workingDirectory: "~", sessionID: nil, access: .edit,
                                        run: DetachedRun(id: "r1"), startAt: Date(timeIntervalSince1970: 1_763_110_000))
        #expect(cmd.contains("w=$(( 1763110000 - $(date +%s) ))"))
        #expect(cmd.contains(#"{"type":"deckhand.waiting","until":%s}"#))
        let plain = LimitAwareRun.command(.codex, prompt: "x", workingDirectory: "~", sessionID: nil, access: .edit, run: DetachedRun(id: "r1"))
        #expect(!plain.contains("w=$(("))
    }
}
