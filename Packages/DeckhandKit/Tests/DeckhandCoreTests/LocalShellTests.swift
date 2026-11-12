import Foundation
import Testing
@testable import DeckhandCore

#if os(macOS)
struct LocalShellTests {
    @Test func returnsOutputAndExitCode() async throws {
        let r = try await LocalShell().run("echo out; echo err >&2; exit 3", timeout: .seconds(10))
        #expect(r.stdout == "out\n")
        #expect(r.stderr == "err\n")
        #expect(r.exitCode == 3)
    }

    /// More than a pipe buffer of output must not block the command.
    @Test func largeOutput() async throws {
        let r = try await LocalShell().run("head -c 2000000 /dev/zero | tr '\\\\0' x", timeout: .seconds(20))
        #expect(r.stdout.utf8.count == 2_000_000)
        #expect(r.exitCode == 0)
    }

    /// Like `timeout(1)` on the server: the command is stopped and the exit code is 124.
    @Test func stopsAfterTheTimeout() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let r = try await LocalShell().run("echo begin; sleep 30", timeout: .seconds(1))
        #expect(clock.now - start < .seconds(10))
        #expect(r.exitCode == 124)
        #expect(r.stdout == "begin\n")
    }

    /// A background child that inherits stdout must not keep the call waiting.
    @Test func backgroundChildDoesNotBlock() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let r = try await LocalShell().run("sleep 20 & echo done", timeout: .seconds(30))
        #expect(clock.now - start < .seconds(10))
        #expect(r.stdout == "done\n")
        #expect(r.exitCode == 0)
    }

    @Test func stdinIsEmpty() async throws {
        let r = try await LocalShell().run("cat; echo end", timeout: .seconds(10))
        #expect(r.stdout == "end\n")
    }
}
#endif
