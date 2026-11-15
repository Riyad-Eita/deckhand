import Foundation
import Testing
@testable import DeckhandCore

struct AgentSchedulesTests {
    let schedule = AgentSchedule(
        id: "ab12cd34", name: "Weekly updates", prompt: "Install security updates and restart what needs it.",
        cli: .claudeCode, directory: "~", access: .edit, cron: "0 6 * * 1",
        options: CLIOptions(model: "sonnet", maxBudgetUSD: 2), notifyTopic: "https://ntfy.sh/deckhand-test")

    @Test func idsAreShortAndSafe() {
        let id = AgentSchedules.newID()
        #expect(AgentSchedules.isValidID(id))
        #expect(!AgentSchedules.isValidID("ab12cd3"))
        #expect(!AgentSchedules.isValidID("ab12cd3;"))
        #expect(!AgentSchedules.isValidID("AB12CD34"))
        #expect(AgentSchedules.deleteCommand(id: "../../x").contains("@@failed"))
    }

    @Test func cronLineIsTaggedAndCommentedWhilePaused() {
        #expect(AgentSchedules.cronLine(schedule) == "0 6 * * 1 bash ~/.deckhand/schedules/ab12cd34.sh >/dev/null 2>&1 # deckhand-schedule ab12cd34")
        var paused = schedule
        paused.paused = true
        #expect(AgentSchedules.cronLine(paused).hasPrefix("#0 6 * * 1 bash"))
    }

    @Test func runnerUsesTheSameEngineAsTheApp() {
        let script = AgentSchedules.runnerScript(schedule)
        #expect(script.contains("claude -p"))
        #expect(script.contains("--permission-mode acceptEdits"))
        #expect(script.contains("--model") && script.contains("sonnet"))
        #expect(script.contains("--max-budget-usd 2.00"))
        #expect(script.contains("dh_wait"))                   // usage limits wait and resume like any task
        #expect(script.contains("https://ntfy.sh/deckhand-test"))
        #expect(script.contains("Done: Weekly updates"))
        #expect(script.contains("skipped"))                   // no overlapping runs
    }

    @Test func plainWords() {
        #expect(schedule.when == "Mon at 06:00")
        var daily = schedule
        daily.cron = "30 2 * * *"
        #expect(daily.when == "Every day at 02:30")
    }

    @Test func parsesTheList() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .secondsSince1970
        let json = String(decoding: try enc.encode(schedule), as: UTF8.self)
        var b = schedule
        b.id = "zz99yy88"; b.name = "Daily backup check"; b.cli = .codex
        let jsonB = String(decoding: try enc.encode(b), as: UTF8.self)
        let out = """
        @@sched ab12cd34
        \(json)
        @@cron on
        @@last s-ab12cd34-20261116-060000 ended 1 1794808800
        @@reason {"type":"result","is_error":true,"result":"apt-get: could not get lock /var/lib/dpkg/lock"}
        @@log 1794808800 started s-ab12cd34-20261116-060000
        @@sched zz99yy88
        \(jsonB)
        @@cron paused
        @@last s-zz99yy88-20261116-070000 waiting 1794816000 1794812400
        @@log 1794812460 skipped s-zz99yy88-20261116-070000
        """
        let list = AgentSchedules.parseList(out)
        #expect(list.map(\.id) == ["zz99yy88", "ab12cd34"])   // sorted by name
        let a = try #require(list.first { $0.id == "ab12cd34" })
        #expect(a.cron == .on)
        #expect(a.schedule.prompt == schedule.prompt)
        #expect(a.schedule.maxBudgetUSD == 2)
        #expect(a.last?.failed == true)
        #expect(a.last?.reason == "apt-get: could not get lock /var/lib/dpkg/lock")
        #expect(a.last?.started == Date(timeIntervalSince1970: 1_794_808_800))
        let z = try #require(list.first { $0.id == "zz99yy88" })
        #expect(z.cron == .paused)
        #expect(z.last?.status == .waiting(until: Date(timeIntervalSince1970: 1_794_816_000)))
        #expect(z.skipped == Date(timeIntervalSince1970: 1_794_812_460))
    }

    @Test func failureReasons() {
        #expect(AgentSchedules.reason(fromLine: #"{"type":"turn.failed","error":{"message":"stream disconnected"}}"#) == "stream disconnected")
        #expect(AgentSchedules.reason(fromLine: #"{"type":"error","message":"Not logged in"}"#) == "Not logged in")
        #expect(AgentSchedules.reason(fromLine: "bash: claude: command not found") == "bash: claude: command not found")
        #expect(AgentSchedules.reason(fromLine: "  ") == nil)
        #expect(AgentSchedules.reason(fromLine: String(repeating: "x", count: 500))?.count == 300)
    }

    /// Runs the real runner in a throwaway HOME with a fake `claude`: one run starts, records itself for the
    /// schedule and the job list, and a second start while it's going is skipped. The crontab isn't touched.
    @Test func runnerStartsADetachedRunAndSkipsOverlaps() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dh-sched-\(UUID().uuidString.prefix(6))")
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = """
        #!/bin/bash
        echo '{"type":"system","subtype":"init","session_id":"s-1"}'
        sleep 2
        echo '{"type":"result","is_error":false,"result":"all good","usage":{}}'
        """
        try fake.write(to: bin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        var s = schedule
        s.notifyTopic = nil
        let dir = home.appendingPathComponent(".deckhand/schedules")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AgentSchedules.runnerScript(s).write(to: dir.appendingPathComponent("ab12cd34.sh"), atomically: true, encoding: .utf8)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        try enc.encode(s).write(to: dir.appendingPathComponent("ab12cd34.json"))

        func sh(_ command: String) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "chmod +x '\(bin.path)/claude'; " + command]
            p.environment = ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"]
            let out = Pipe()
            p.standardOutput = out
            try p.run(); p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        let first = try sh(AgentSchedules.runNowCommand(id: "ab12cd34"))
        #expect(first.hasPrefix("@@run s-ab12cd34-"))
        #expect(try sh(AgentSchedules.runNowCommand(id: "ab12cd34")).contains("@@skipped"))
        let runID = first.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@@run ", with: "")
        let runs = DetachedRun.parseList(try sh(DetachedRun.listCommand))
        let info = try #require(runs.first { $0.id == runID })
        #expect(info.meta?.schedule == "ab12cd34")
        #expect(info.meta?.title == "Weekly updates")
        #expect(abs((info.meta?.started.timeIntervalSinceNow ?? -999)) < 30)

        for _ in 0..<40 where !FileManager.default.fileExists(atPath: home.path + "/.deckhand/runs/\(runID).exit") {
            try await Task.sleep(for: .milliseconds(250))
        }
        let list = AgentSchedules.parseList(try sh(AgentSchedules.listCommand))
        #expect(list.first?.last?.run.id == runID)
        #expect(list.first?.last?.status == .ended(exitCode: 0))
        #expect(list.first?.skipped != nil)
        let out = try String(contentsOfFile: home.path + "/.deckhand/runs/\(runID).out", encoding: .utf8)
        #expect(out.contains("all good"))
    }
}
