import Foundation
import Testing
@testable import DeckhandCore

@Suite struct LogsTests {
    @Test func parsesSources() {
        let out = "@@journal\n1762700000.1 3083 /var/log/fontconfig.log\n1762800000.5 1176 /home/me/app/logs/app.log\n1762800000.5 1176 /home/me/app/logs/app.log\nbroken line\n"
        let s = Logs.parseSources(out)
        #expect(s == [.journal(unit: nil), .file(path: "/var/log/fontconfig.log", size: 3083), .file(path: "/home/me/app/logs/app.log", size: 1176)])
        #expect(s[2].title == "app.log")
    }

    @Test(arguments: [
        ("2026-11-09 09:15:03 ERROR city not found: /paris", LogLevel.error),
        ("2026-11-09 09:14:22 WARN  slow response 812ms /oslo", .warning),
        ("Nov 10 nginx[12]: [crit] 1234#0: worker failed", .error),
        ("2026-11-09 09:12:01 INFO  started on :8080", .info),
        ("Traceback (most recent call last):", .error),
    ])
    func levels(_ line: String, _ level: LogLevel) {
        #expect(Logs.level(of: line) == level)
    }

    @Test func readsAndFiltersLocally() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "app-\(UUID().uuidString.prefix(6)).log").path
        try "a INFO ok\nb ERROR boom\nc WARN slow\nd INFO fine\n".write(toFile: path, atomically: true, encoding: .utf8)
        let src = LogSource.file(path: path, size: 0)
        let all = try await LocalShell().run(Logs.readCommand(src, lines: 3), timeout: .seconds(5))
        #expect(all.stdout == "b ERROR boom\nc WARN slow\nd INFO fine\n")
        let errs = try await LocalShell().run(Logs.readCommand(src, lines: 10, errorsOnly: true), timeout: .seconds(5))
        #expect(errs.stdout == "b ERROR boom\nc WARN slow\n")
    }

    @Test func explainPromptUsesProblems() {
        let lines = ["x INFO a", "y ERROR b", "z WARN c"].enumerated().map { LogLine(id: $0.offset, text: $0.element) }
        let p = Logs.explainPrompt(source: .file(path: "/var/log/app.log", size: 10), lines: lines)
        #expect(p.contains("y ERROR b") && p.contains("z WARN c") && !p.contains("x INFO a"))
    }
}
