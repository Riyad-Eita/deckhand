import Foundation
import Testing
@testable import DeckhandCore

/// Runs every command with a temporary HOME whose login profile puts a fake CLI first on the PATH.
private struct FakeHomeShell: StreamingShell {
    let home: String
    func wrap(_ command: String) -> String { "HOME='\(home)' /bin/bash -c \(ShellQuote.quote(command))" }
    func run(_ command: String, timeout: Duration) async throws -> CommandResult {
        try await LocalShell().run(wrap(command), timeout: timeout)
    }
    func streamLines(_ command: String) -> AsyncThrowingStream<String, Error> { LocalShell().streamLines(wrap(command)) }
}

@Suite(.serialized) struct LimitAwareTests {
    /// A fake `claude`: the first turn hits a usage limit that resets in a second, `--resume` finishes the task.
    func fakeHome() throws -> String {
        let home = FileManager.default.temporaryDirectory.appending(path: "la-\(UUID().uuidString.prefix(6))").path
        let bin = home + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let claude = #"""
        #!/bin/bash
        case " $* " in
          *" --resume "*)
            echo '{"type":"system","subtype":"init","session_id":"s-1"}'
            echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"resumed: $2\"}]}}"
            echo '{"type":"result","subtype":"success","is_error":false,"result":"ok","usage":{}}'
            ;;
          *)
            echo '{"type":"system","subtype":"init","session_id":"s-1"}'
            echo '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
            echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"result\":\"Claude AI usage limit reached|$(( $(date +%s) + 1 ))\",\"usage\":{}}"
            exit 1
            ;;
        esac
        """#
        try claude.write(toFile: bin + "/claude", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/claude")
        try "export PATH=\"$HOME/bin:$PATH\" DH_SLACK=0\n".write(toFile: home + "/.bash_profile", atomically: true, encoding: .utf8)
        return home
    }

    @Test func waitsForTheLimitAndContinuesTheSession() async throws {
        let shell = FakeHomeShell(home: try fakeHome())
        let run = DetachedRun()
        let meta = DetachedRun.Meta(title: "Fix the build", engine: "Claude Code", directory: "~")
        var texts: [String] = []
        var waited: Date?
        var finished = false
        for try await event in ServerCLIRun.runDetached(
            .claudeCode, shell: shell, prompt: "fix it", workingDirectory: "~", sessionID: nil, access: .edit, run: run, meta: meta)
        {
            switch event {
            case .message(let m): texts += m.blocks.compactMap { if case .text(let t) = $0 { t } else { nil } }
            case .waitingForLimit(let until): waited = until
            case .finished(.endTurn): finished = true
            default: break
            }
        }
        #expect(waited != nil)
        #expect(texts.first == "working")
        #expect(texts.last?.hasPrefix("resumed: You were paused by a usage limit") == true)
        #expect(finished)

        // The job list sees the finished run with its description.
        let list = DetachedRun.parseList(try await shell.run(DetachedRun.listCommand, timeout: .seconds(10)).stdout)
        #expect(list.count == 1)
        #expect(list.first?.status == .ended(exitCode: 0))
        #expect(list.first?.meta?.title == "Fix the build")
        _ = try await shell.run(run.deleteCommand, timeout: .seconds(10))
        #expect(try await shell.run(DetachedRun.listCommand, timeout: .seconds(10)).stdout.isEmpty)
    }

    @Test func exactResetTimesDontRollToTomorrow() async throws {
        func wait(_ text: String) async throws -> Int {
            let script = LimitAwareRun.waitFunction + "\nDH_SLACK=0 dh_wait " + ShellQuote.quote(text)
            return Int(try await LocalShell().run("bash -c " + ShellQuote.quote(script), timeout: .seconds(10)).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        }
        let now = Int(Date().timeIntervalSince1970)
        #expect(try await wait("Claude AI usage limit reached|\(now - 5)") == 0)        // already reset: go on now
        let ahead = try await wait("Claude AI usage limit reached|\(now + 120)")
        #expect((115...120).contains(ahead))
        #expect(try await wait("something else") == 1800)
    }

    @Test func otherFailuresStillFail() async throws {
        let shell = FakeHomeShell(home: try fakeHome())
        // A CLI error that isn't a limit ends the run with the CLI's message.
        try "#!/bin/bash\necho '{\"type\":\"result\",\"is_error\":true,\"result\":\"Invalid API key · Please run /login\",\"usage\":{}}'\nexit 1\n"
            .write(toFile: shell.home + "/bin/claude", atomically: false, encoding: .utf8)
        await #expect(throws: CLIError.self) {
            for try await _ in ServerCLIRun.runDetached(
                .claudeCode, shell: shell, prompt: "x", workingDirectory: "~", sessionID: nil, access: .edit, run: DetachedRun()) {}
        }
    }

    @Test func parsesTheJobList() {
        let out = """
        @@run a running
        {"title":"One","engine":"Codex","directory":"~/app","started":200}
        @@run b waiting 1800000000
        {"title":"Two","engine":"Claude Code","directory":"~","started":300}
        @@run c ended 143
        {"title":"Three","engine":"Codex","directory":"~","started":100}
        """
        let list = DetachedRun.parseList(out)
        #expect(list.map(\.id) == ["b", "a", "c"])
        #expect(list[0].status == .waiting(until: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(list[1].status == .running)
        #expect(list[2].status == .ended(exitCode: 143))
        #expect(list[1].meta?.directory == "~/app")
    }
}
