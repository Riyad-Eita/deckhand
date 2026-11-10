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

    /// The run pushes to ntfy when it ends — tested with a fake curl that records its arguments.
    @Test func notifiesWhenDone() async throws {
        let h = try home()
        try FileManager.default.createDirectory(atPath: h + "/bin", withIntermediateDirectories: true)
        try "#!/bin/bash\nprintf '%s\\n' \"$@\" > \"$HOME/curl.args\"\n".write(toFile: h + "/bin/curl", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h + "/bin/curl")
        let run = DetachedRun()
        let notify = DetachedRun.Notify(topicURL: "https://ntfy.example.com/deckhand-test", doneMessage: "Done: Fix it's build",
                                        failedMessage: "Failed", click: "deckhand://thread/abc")
        try "export PATH=\"$HOME/bin:$PATH\"\n".write(toFile: h + "/.bash_profile", atomically: true, encoding: .utf8)
        _ = try await sh(h, run.startCommand("echo hi", notify: notify))
        _ = try await sh(h, run.readCommand(fromLine: 1))
        // The push runs right after the exit code is written: wait for it (up to 5 s).
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: h + "/curl.args") { try await Task.sleep(for: .milliseconds(100)) }
        let args = try String(contentsOfFile: h + "/curl.args", encoding: .utf8)
        #expect(args.contains("Done: Fix it's build"))
        #expect(args.contains("Click: deckhand://thread/abc"))
        #expect(args.contains("https://ntfy.example.com/deckhand-test"))
    }

    @Test func markers() {
        #expect(DetachedRun.marker("@@exit 0") == .exit(0))
        #expect(DetachedRun.marker("@@missing") == .missing)
        #expect(DetachedRun.marker("{\"type\":\"x\"}") == nil)
    }
}
