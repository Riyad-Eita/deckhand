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

public enum ShellQuote {
    /// POSIX single-quote escaping: `it's` → `'it'\''s'`.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Runs commands with `/bin/sh` on this machine. Used in tests and the Mac debug build.
public struct LocalShell: RemoteShell {
    public init() {}

    public func run(_ command: String, timeout: Duration) async throws -> CommandResult {
        #if os(macOS)
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { p in
                let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: CommandResult(stdout: stdout, stderr: stderr, exitCode: p.terminationStatus))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }
}
