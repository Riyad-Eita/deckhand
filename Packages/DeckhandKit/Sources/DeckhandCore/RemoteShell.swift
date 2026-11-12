import Foundation

public struct CommandResult: Sendable, Hashable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public init(stdout: String, stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// Something that runs non-interactive shell commands on a host: an SSH connection, or a local shell in tests.
public protocol RemoteShell: Sendable {
    func run(_ command: String, timeout: Duration) async throws -> CommandResult
}

/// A shell that can stream a command's stdout line by line (for long-running CLI agents).
public protocol StreamingShell: RemoteShell {
    /// Yields stdout lines as they arrive. Throws `CLIError` with stderr when the command exits non-zero.
    func streamLines(_ command: String) -> AsyncThrowingStream<String, Error>
}

public enum ShellQuote {
    /// POSIX single-quote escaping: `it's` → `'it'\''s'`.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Runs commands with `/bin/sh` on this machine. Used in tests and the Mac debug build.
public struct LocalShell: StreamingShell {
    public init() {}

    /// How long `run` waits for stdout/stderr to close after the command exited.
    static let drainGrace: Double = 1

    public func streamLines(_ command: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let r = try await run(command, timeout: .seconds(600))
                    for line in r.stdout.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
                        continuation.yield(String(line))
                    }
                    if r.exitCode != 0 { throw CLIError(r.stderr.isEmpty ? "exit code \(r.exitCode)" : r.stderr) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Behaves like the SSH shell: stdin is empty, the command is stopped after `timeout` (exit code 124, like
    /// `timeout(1)`), and output is read while the command runs, so large output can't fill the pipe and block it.
    /// A background child that keeps stdout open doesn't hold the result: after the command exits we wait at most
    /// `drainGrace` for the pipes to close and return what arrived.
    public func run(_ command: String, timeout: Duration) async throws -> CommandResult {
        #if os(macOS)
        let state = LocalRunState()
        return try await withCheckedThrowingContinuation { continuation in
            state.continuation = continuation
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            // One thread per pipe with blocking reads until real end-of-file. (readabilityHandler + availableData can
            // report an empty read under load, which looked like EOF and dropped the rest of the output.)
            for (handle, isErr) in [(out.fileHandleForReading, false), (err.fileHandleForReading, true)] {
                Thread.detachNewThread {
                    let fd = handle.fileDescriptor
                    var buf = [UInt8](repeating: 0, count: 65_536)
                    while true {
                        let n = read(fd, &buf, buf.count)
                        if n > 0 { state.append(Data(buf[0..<n]), stderr: isErr); continue }
                        if n < 0 && errno == EINTR { continue }
                        break
                    }
                    withExtendedLifetime(handle) { state.pipeClosed() }
                }
            }
            process.terminationHandler = { p in
                state.exited(p.terminationStatus)
                DispatchQueue.global().asyncAfter(deadline: .now() + LocalShell.drainGrace) { state.finish() }
            }
            do { try process.run() } catch {
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                state.fail(error)
                return
            }
            let pid = process.processIdentifier
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + max(seconds, 0.1)) {
                guard state.markTimedOut() else { return }
                kill(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if state.isRunning { kill(pid, SIGKILL) } }
            }
        }
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }
}

#if os(macOS)
/// Shared state of one `LocalShell.run`: collected output, exit status and the continuation, resumed exactly once.
private final class LocalRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data(), stderr = Data()
    private var openPipes = 2
    private var status: Int32?
    private var timedOut = false
    private var done = false
    var continuation: CheckedContinuation<CommandResult, Error>?

    var isRunning: Bool { lock.withLock { status == nil } }

    func append(_ data: Data, stderr isErr: Bool) {
        lock.withLock { if isErr { stderr.append(data) } else { stdout.append(data) } }
    }

    func pipeClosed() {
        let closed = lock.withLock { openPipes -= 1; return openPipes == 0 && status != nil }
        if closed { finish() }
    }

    func exited(_ code: Int32) {
        let closed = lock.withLock { status = code; return openPipes == 0 }
        if closed { finish() }
    }

    /// True if the command was still running and is now marked as timed out.
    func markTimedOut() -> Bool {
        lock.withLock {
            guard status == nil, !done else { return false }
            timedOut = true
            return true
        }
    }

    func finish() {
        let result: CommandResult? = lock.withLock {
            guard !done, let status else { return nil }
            done = true
            return CommandResult(stdout: String(decoding: stdout, as: UTF8.self),
                                 stderr: String(decoding: stderr, as: UTF8.self),
                                 exitCode: timedOut ? 124 : status)
        }
        if let result { continuation?.resume(returning: result); continuation = nil }
    }

    func fail(_ error: Error) {
        let first = lock.withLock { () -> Bool in
            guard !done else { return false }
            done = true
            return true
        }
        if first { continuation?.resume(throwing: error); continuation = nil }
    }
}
#endif
