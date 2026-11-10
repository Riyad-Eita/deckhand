import Foundation
import Testing
@testable import DeckhandCore

@Suite(.serialized) struct DetachedRunTests {
    func home() throws -> String {
        let h = FileManager.default.temporaryDirectory.appending(path: "dr-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: h, withIntermediateDirectories: true)
        return h
    }

    func sh(_ home: String, _ cmd: String) async throws -> CommandResult {
        try await LocalShell().run("HOME='\(home)' /bin/bash -c \(ShellQuote.quote(cmd))", timeout: .seconds(30))
    }

    @Test func runsDetachedAndCanBeReadFromAnyLine() async throws {
        let h = try home()
        let run = DetachedRun()
        let started = try await sh(h, run.startCommand("for i in 1 2 3 4; do echo line$i; sleep 0.3; done"))
        #expect(started.stdout.contains("started"))
        let all = try await sh(h, run.readCommand(fromLine: 1))
        #expect(all.stdout.hasPrefix("line1\nline2\nline3\nline4\n"))
        #expect(all.stdout.contains("@@exit 0"))
        // Reattach later from line 3: only the rest comes back.
        let rest = try await sh(h, run.readCommand(fromLine: 3))
        #expect(rest.stdout.hasPrefix("line3\nline4\n"))
        #expect(try await sh(h, run.statusCommand).stdout == "ended\n")
    }

    @Test func stopEndsTheRun() async throws {
        let h = try home()
        let run = DetachedRun()
        _ = try await sh(h, run.startCommand("echo begin; sleep 30; echo never"))
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await sh(h, run.statusCommand).stdout == "running\n")
        _ = try await sh(h, run.stopCommand)
        let out = try await sh(h, run.readCommand(fromLine: 1))
        #expect(out.stdout.contains("begin"))
        #expect(!out.stdout.contains("never"))
        #expect(out.stdout.contains("@@exit 143"))
    }

    @Test func markers() {
        #expect(DetachedRun.marker("@@exit 0") == .exit(0))
        #expect(DetachedRun.marker("@@missing") == .missing)
        #expect(DetachedRun.marker("{\"type\":\"x\"}") == nil)
    }
}
