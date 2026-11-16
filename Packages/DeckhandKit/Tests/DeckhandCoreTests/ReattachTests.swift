import Foundation
import Testing
@testable import DeckhandCore

/// Reattaching to a run must never start it again — also from line 1 (an app closed before the first line arrived,
/// or a run the server started by itself and the app only opens).
struct ReattachTests {
    final class RecordingShell: StreamingShell, @unchecked Sendable {
        var commands: [String] = []
        func run(_ command: String, timeout: Duration) async throws -> CommandResult {
            commands.append(command)
            return CommandResult(stdout: "started\n")
        }
        func streamLines(_ command: String) -> AsyncThrowingStream<String, Error> {
            commands.append(command)
            return AsyncThrowingStream { c in c.yield("@@exit 0"); c.finish() }
        }
    }

    func drain(_ s: AsyncThrowingStream<AgentEvent, Error>) async throws { for try await _ in s {} }

    @Test func reattachFromLineOneDoesNotStart() async throws {
        let shell = RecordingShell()
        // The stand-in run has no result line, so the stream ends with an error; only the commands matter here.
        _ = try? await drain(ServerCLIRun.runDetached(.claudeCode, shell: shell, prompt: "", workingDirectory: "~", sessionID: nil,
                                                      access: .readOnly, run: DetachedRun(id: "r1"), fromLine: 1, start: false))
        #expect(!shell.commands.contains { $0.contains("nohup") }, "\(shell.commands)")
        #expect(shell.commands.contains { $0.contains("tail -n +1") })
    }

    @Test func aNewTurnStarts() async throws {
        let shell = RecordingShell()
        _ = try? await drain(ServerCLIRun.runDetached(.claudeCode, shell: shell, prompt: "hi", workingDirectory: "~", sessionID: nil,
                                                      access: .readOnly, run: DetachedRun(id: "r2"), fromLine: 1, start: true))
        #expect(shell.commands.first?.contains("nohup") == true)
    }
}
