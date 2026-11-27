import Foundation
import Testing
@testable import DeckhandCore

/// Runs the scripts locally against a stand-in `sudo` that only accepts `-A` with the right password.
@Suite(.serialized) struct RunSudoTests {
    static let fakeSudo = #"""
    #!/bin/sh
    printf '%s\n' "$*" >> "$HOME/sudo-args"
    A=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -A) A=1; shift ;;
        -n|-S) echo "no terminal" >&2; exit 9 ;;
        -u) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
      esac
    done
    [ "$A" = 1 ] && [ "$("$SUDO_ASKPASS")" = "s3cret" ] || { echo "a password is required" >&2; exit 1; }
    exec "$@"
    """#

    func home() throws -> String {
        let h = FileManager.default.temporaryDirectory.appending(path: "rs-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: h + "/bin", withIntermediateDirectories: true)
        try Self.fakeSudo.write(toFile: h + "/bin/sudo", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h + "/bin/sudo")
        return h
    }

    func sh(_ home: String, _ cmd: String, stdin: String? = nil) async throws -> String {
        let input = stdin.map { " <<'EOF'\n\($0)\nEOF" } ?? ""
        return try await LocalShell().run(
            "HOME='\(home)' PATH='\(home)/bin':/usr/bin:/bin /bin/bash -c \(ShellQuote.quote(cmd))\(input)", timeout: .seconds(30)
        ).stdout
    }

    @Test func wrongPasswordLeavesNothingBehind() async throws {
        let h = try home()
        let run = DetachedRun()
        #expect(RunSudo.parse(try await sh(h, RunSudo.prepareCommand(run), stdin: "nope")) == .wrongPassword)
        #expect(!FileManager.default.fileExists(atPath: h + "/.deckhand/runs/\(run.id).sudo"))
    }

    @Test func wrapperDropsNonInteractiveFlagsAndAnswersWithTheStoredPassword() async throws {
        let h = try home()
        let run = DetachedRun()
        #expect(RunSudo.parse(try await sh(h, RunSudo.prepareCommand(run), stdin: "s3cret")) == .ok)
        let d = h + "/.deckhand/runs/\(run.id).sudo"
        let attrs = try FileManager.default.attributesOfItem(atPath: d)
        #expect((attrs[.posixPermissions] as? Int) == 0o700)
        #expect(try String(contentsOfFile: d + "/pw", encoding: .utf8) == "s3cret\n")

        // -n and -S go, options with values stay, flags after the command are the command's own.
        let out = try await sh(h, "\(d)/sudo -n -u root -S echo -n done")
        #expect(out == "done")
        let args = try String(contentsOfFile: h + "/sudo-args", encoding: .utf8)
        #expect(args.hasSuffix("-A -u root echo -n done\n"))
    }

    @Test func detachedRunUsesSudoAndRemovesThePasswordWhenItEnds() async throws {
        let h = try home()
        let run = DetachedRun()
        #expect(RunSudo.parse(try await sh(h, RunSudo.prepareCommand(run), stdin: "s3cret")) == .ok)
        _ = try await sh(h, run.startCommand(RunSudo.wrap("sudo -n echo as-root; sudo whoami >/dev/null && echo again", run: run)))
        let read = try await sh(h, run.readCommand(fromLine: 1))
        #expect(read.contains("as-root"))
        #expect(read.contains("again"))
        #expect(read.contains("@@exit 0"))
        #expect(!FileManager.default.fileExists(atPath: h + "/.deckhand/runs/\(run.id).sudo"))
    }

    @Test func stoppingARunRemovesThePassword() async throws {
        let h = try home()
        let run = DetachedRun()
        #expect(RunSudo.parse(try await sh(h, RunSudo.prepareCommand(run), stdin: "s3cret")) == .ok)
        _ = try await sh(h, run.startCommand(RunSudo.wrap("sleep 30", run: run)))
        try await Task.sleep(for: .milliseconds(500))
        _ = try await sh(h, run.stopCommand)
        try await Task.sleep(for: .milliseconds(500))
        #expect(!FileManager.default.fileExists(atPath: h + "/.deckhand/runs/\(run.id).sudo"))
    }

    @Test func passwordNeverAppearsInTheCommands() {
        let run = DetachedRun()
        for c in [RunSudo.prepareCommand(run), RunSudo.wrap("x", run: run)] { #expect(!c.contains("s3cret")) }
    }
}
