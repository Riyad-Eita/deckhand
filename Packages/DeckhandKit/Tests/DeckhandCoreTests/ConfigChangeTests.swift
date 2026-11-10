import Foundation
import Testing
@testable import DeckhandCore

/// Runs commands with bash on this Mac; `openChannel` gives the process a stdin we can write to.
struct LocalChannelShell: ChannelShell {
    var env: [String: String] = [:]

    func run(_ command: String, timeout: Duration) async throws -> CommandResult {
        try await LocalShell().run(prefix + command, timeout: timeout)
    }
    func streamLines(_ command: String) -> AsyncThrowingStream<String, Error> { LocalShell().streamLines(prefix + command) }
    var prefix: String { env.map { "export \($0.key)=\(ShellQuote.quote($0.value)); " }.joined() }

    func openChannel(_ command: String) async throws -> any LineChannel {
        try LocalChannel(command: prefix + command)
    }
}

final class LocalChannel: LineChannel, @unchecked Sendable {
    let lines: AsyncThrowingStream<String, Error>
    private let process = Process()
    private let stdin = Pipe()

    init(command: String) throws {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        lines = stream
        let out = Pipe(), buffer = LineBuffer()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = out
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; continuation.finish(); return }
            for line in buffer.append(data) { continuation.yield(line) }
        }
        try process.run()
    }

    func send(_ line: String) async throws { stdin.fileHandleForWriting.write(Data((line + "\n").utf8)) }
    /// Ends the process only if it hangs: terminating it right away would also take down background jobs
    /// it started (macOS has no `setsid`; on Linux servers the guard runs in its own session).
    func close() {
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { p.terminate() } }
    }
}

@Suite(.serialized) struct ConfigChangeTests {
    let shell = LocalChannelShell()

    func sandbox() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cc-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: dir + "/etc", withIntermediateDirectories: true)
        try "Port 22\nPasswordAuthentication yes\n".write(toFile: dir + "/etc/app.conf", atomically: true, encoding: .utf8)
        return dir
    }

    func runAsRoot(_ script: String) async throws -> (lines: [String], exit: Int32?) {
        var lines: [String] = [], exit: Int32?
        for try await l in Sudo.run(script, on: shell, access: .root, password: nil) {
            switch l { case .output(let s): lines.append(s); case .exit(let c): exit = c }
        }
        return (lines, exit)
    }

    func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    @Test func appliesShowsDiffAndRollsBack() async throws {
        let d = try sandbox()
        let change = ConfigChange(
            title: "Turn off passwords", files: ["\(d)/etc/app.conf", "\(d)/etc/extra.conf"],
            apply: "sed -i.bak 's/^PasswordAuthentication yes/PasswordAuthentication no/' \(d)/etc/app.conf; rm -f \(d)/etc/app.conf.bak; echo 'MaxAuthTries 3' > \(d)/etc/extra.conf",
            validate: "grep -q '^Port ' \(d)/etc/app.conf", reload: "echo reloaded")
        let id = ConfigChange.makeID(title: change.title, date: Date(timeIntervalSince1970: 1_794_300_000))
        #expect(id == "20261110-084000-turn-off-passwords")
        let r = try await runAsRoot(change.script(id: id, root: d + "/backups"))
        #expect(r.exit == 0)
        #expect(r.lines.map(ConfigChange.event).contains(.done))
        #expect(r.lines.contains("reloaded"))
        #expect(read(d + "/etc/app.conf")?.contains("PasswordAuthentication no") == true)

        let history = ConfigChange.parseList(try await shell.run(ConfigChange.listCommand(root: d + "/backups"), timeout: .seconds(10)).stdout)
        #expect(history.map(\.id) == [id])
        #expect(history.first?.status == .applied)
        #expect(history.first?.files.count == 2)

        let diff = try await runAsRoot(ConfigChange.diffScript(id: id, root: d + "/backups")).lines.joined(separator: "\n")
        #expect(diff.contains("-PasswordAuthentication yes"))
        #expect(diff.contains("+PasswordAuthentication no"))
        #expect(diff.contains("+MaxAuthTries 3"))

        let back = try await runAsRoot(ConfigChange.rollbackScript(id: id, root: d + "/backups"))
        #expect(back.lines.map(ConfigChange.event).contains(.done))
        #expect(read(d + "/etc/app.conf") == "Port 22\nPasswordAuthentication yes\n")
        #expect(!FileManager.default.fileExists(atPath: d + "/etc/extra.conf"))
        let after = ConfigChange.parseList(try await shell.run(ConfigChange.listCommand(root: d + "/backups"), timeout: .seconds(10)).stdout)
        #expect(after.first?.status == .rolledback)
    }

    @Test func failedValidationRestoresAtOnce() async throws {
        let d = try sandbox()
        let change = ConfigChange(
            title: "Broken", files: ["\(d)/etc/app.conf"],
            apply: "echo 'garbage line' >> \(d)/etc/app.conf", validate: "! grep -q garbage \(d)/etc/app.conf")
        let r = try await runAsRoot(change.script(id: "x", root: d + "/b"))
        #expect(r.exit == 1)
        #expect(r.lines.map(ConfigChange.event).contains(.failed("validate")))
        #expect(read(d + "/etc/app.conf") == "Port 22\nPasswordAuthentication yes\n")
        #expect(ConfigChange.parseList(try await shell.run(ConfigChange.listCommand(root: d + "/b"), timeout: .seconds(10)).stdout).first?.status == .failed)
    }

    @Test func failingApplyStopsAndRestores() async throws {
        let d = try sandbox()
        let change = ConfigChange(
            title: "Half done", files: ["\(d)/etc/app.conf"],
            apply: "echo 'first' >> \(d)/etc/app.conf\nfalse\necho 'never' >> \(d)/etc/app.conf")
        let r = try await runAsRoot(change.script(id: "y", root: d + "/b"))
        #expect(r.lines.map(ConfigChange.event).contains(.failed("apply")))
        #expect(read(d + "/etc/app.conf") == "Port 22\nPasswordAuthentication yes\n")
    }

    @Test func guardRollsBackUnlessConfirmed() async throws {
        let d = try sandbox()
        let original = "Port 22\nPasswordAuthentication yes\n"
        func change() -> ConfigChange {
            ConfigChange(title: "Risky", files: ["\(d)/etc/app.conf"], apply: "echo 'Port 2222' > \(d)/etc/app.conf",
                         verify: "grep -q 2222 \(d)/etc/app.conf", guardSeconds: 2)
        }
        // Not confirmed: the server puts the old file back by itself.
        let r = try await runAsRoot(change().script(id: "g1", root: d + "/b"))
        #expect(r.lines.map(ConfigChange.event).contains(.guarded(2)))
        #expect(ConfigChange.parseList(try await shell.run(ConfigChange.listCommand(root: d + "/b"), timeout: .seconds(10)).stdout).first?.status == .pending)
        try await Task.sleep(for: .seconds(4))
        #expect(read(d + "/etc/app.conf") == original)
        #expect(ConfigChange.parseList(try await shell.run(ConfigChange.listCommand(root: d + "/b"), timeout: .seconds(10)).stdout).first?.status == .rolledback)

        // Confirmed in time: the change stays.
        _ = try await runAsRoot(change().script(id: "g2", root: d + "/c"))
        let ok = try await runAsRoot(ConfigChange.confirmScript(id: "g2", root: d + "/c"))
        #expect(ok.lines.contains("@@done"))
        try await Task.sleep(for: .seconds(4))
        #expect(read(d + "/etc/app.conf") == "Port 2222\n")
        #expect(ConfigChange.parseList(try await shell.run(ConfigChange.listCommand(root: d + "/c"), timeout: .seconds(10)).stdout).first?.status == .applied)
    }

    @Test func failedVerifyRestores() async throws {
        let d = try sandbox()
        let change = ConfigChange(title: "No effect", files: ["\(d)/etc/app.conf"], apply: "echo 'Port 1' > \(d)/etc/app.conf", verify: "false")
        let r = try await runAsRoot(change.script(id: "v", root: d + "/b"))
        #expect(r.lines.map(ConfigChange.event).contains(.failed("verify")))
        #expect(read(d + "/etc/app.conf") == "Port 22\nPasswordAuthentication yes\n")
    }

    /// A fake `sudo` that asks for a password on stderr like `sudo -S -p` does.
    func fakeSudoShell() throws -> LocalChannelShell {
        let bin = FileManager.default.temporaryDirectory.appending(path: "sudo-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let sudo = #"""
        #!/bin/bash
        # usage: sudo -S -p PROMPT bash -c SCRIPT
        prompt="$3"; shift 3
        for i in 1 2 3; do
          printf '%s' "$prompt" >&2
          IFS= read -r pw || exit 1
          [ "$pw" = "s3cret" ] && exec "$@"
          echo "Sorry, try again." >&2
        done
        exit 1
        """#
        try sudo.write(toFile: bin + "/sudo", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/sudo")
        return LocalChannelShell(env: ["PATH": "\(bin):/usr/bin:/bin"])
    }

    @Test func sudoPasswordGoesOverStdin() async throws {
        let shell = try fakeSudoShell()
        var out: [RootLine] = []
        for try await l in Sudo.run("echo hello from root", on: shell, access: .password, password: "s3cret") { out.append(l) }
        #expect(out == [.output("hello from root"), .exit(0)])
        // The password is not part of the command.
        #expect(!Sudo.command("echo hi", access: .password).contains("s3cret"))
    }

    @Test func wrongSudoPasswordIsReported() async throws {
        let shell = try fakeSudoShell()
        await #expect(throws: SudoError.wrongPassword) {
            for try await _ in Sudo.run("echo hi", on: shell, access: .password, password: "nope") {}
        }
    }

    @Test func probe() {
        #expect(Sudo.parseProbe("passwordless\n") == .passwordless)
        #expect(Sudo.parseProbe("some motd\nroot\n") == .root)
        #expect(Sudo.parseProbe("") == .unavailable)
    }
}
