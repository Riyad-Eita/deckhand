import Foundation
import Testing
@testable import DeckhandCore

struct FleetRunTests {
    struct Fails: Error, LocalizedError { var errorDescription: String? { "connection refused" } }
    final class Log: @unchecked Sendable {
        private let lock = NSLock(); private var items: [(UUID, FleetRun.State)] = []
        func add(_ i: UUID, _ s: FleetRun.State) { lock.withLock { items.append((i, s)) } }
        func last(_ i: UUID) -> FleetRun.State? { lock.withLock { items.last { $0.0 == i }?.1 } }
        /// Index of the first event matching `match`.
        func first(_ match: (FleetRun.State) -> Bool) -> Int? { lock.withLock { items.firstIndex { match($0.1) } } }
        func count(_ match: (FleetRun.State) -> Bool) -> Int { lock.withLock { items.filter { match($0.1) }.count } }
    }

    @Test func allAtOnce() async {
        let ids = [UUID(), UUID(), UUID()]
        let targets = [
            FleetRun.Target(id: ids[0]) { LocalShell() },
            FleetRun.Target(id: ids[1]) { LocalShell() },
            FleetRun.Target(id: ids[2]) { throw Fails() },
        ]
        let log = Log()
        await FleetRun.run("sleep 1; echo hi", on: targets, stopOnFailure: false) { log.add($0, $1) }
        // In parallel: every server started before the first one finished (no wall-clock limit — CI runners vary).
        let firstDone = log.first { if case .done = $0 { true } else { false } } ?? 0
        #expect(log.count { $0 == .running } == 3)
        #expect((log.first { $0 == .running } ?? 99) < firstDone)
        #expect(log.count { $0 == .running } == 3 && firstDone >= 3)
        if case .done(let code, let out, _) = log.last(ids[0]) { #expect(code == 0 && out == "hi") } else { Issue.record("not done") }
        #expect(log.last(ids[2]) == .failed("connection refused"))
    }

    @Test func stopsAtTheFirstFailure() async {
        let ids = [UUID(), UUID(), UUID()]
        let targets = ids.map { id in FleetRun.Target(id: id) { LocalShell() } }
        let log = Log()
        let marker = FileManager.default.temporaryDirectory.appending(path: "fleet-\(UUID().uuidString.prefix(6))").path
        // The first run succeeds, the second fails, the third must not run at all.
        await FleetRun.run("n=$(cat '\(marker)' 2>/dev/null || echo 0); echo $((n+1)) > '\(marker)'; [ $n -lt 1 ]", on: targets, stopOnFailure: true) { log.add($0, $1) }
        #expect(log.last(ids[0])?.ok == true && log.last(ids[1])?.ok == false && log.last(ids[2]) == .skipped)
        #expect((try? String(contentsOfFile: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
        try? FileManager.default.removeItem(atPath: marker)
    }
}
