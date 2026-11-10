import Foundation

/// A shell that can also run a command with a stdin we write to (an SSH exec channel).
public protocol ChannelShell: StreamingShell {
    func openChannel(_ command: String) async throws -> any LineChannel
}

/// How this user becomes root on the server.
public enum SudoAccess: String, Sendable, Hashable {
    /// Logged in as root.
    case root
    /// `sudo` works without a password.
    case passwordless
    /// `sudo` asks for the user's password.
    case password
    /// No sudo, or the user isn't allowed to use it.
    case unavailable
}

public enum SudoError: Error, LocalizedError, Equatable {
    case wrongPassword
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .wrongPassword: "That sudo password didn't work."
        case .unavailable: "This user can't use sudo on the server. Log in as root or as an admin user."
        }
    }
}

/// One line of a root command: its output, or how it ended.
public enum RootLine: Sendable, Equatable {
    case output(String)
    case exit(Int32)
}

/// Runs scripts as root. The sudo password goes to `sudo -S` over the channel's stdin —
/// never into a command line, where other users could see it in the process list.
public enum Sudo {
    public static let probeCommand = #"""
    if [ "$(id -u)" = 0 ]; then echo root
    elif sudo -n true 2>/dev/null; then echo passwordless
    elif command -v sudo >/dev/null 2>&1 && sudo -n -v 2>&1 | grep -qi password; then echo password
    else echo unavailable; fi
    """#

    public static func parseProbe(_ output: String) -> SudoAccess {
        SudoAccess(rawValue: output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "") ?? .unavailable
    }

    static let prompt = "@@sudo-password"

    /// The command that runs `script` with bash as root; it prints the output, then `@@exit <code>`.
    public static func command(_ script: String, access: SudoAccess) -> String {
        let s = ShellQuote.quote(script)
        let run = switch access {
        case .root, .unavailable: "bash -c \(s)"
        case .passwordless: "sudo -n bash -c \(s)"
        case .password: "sudo -S -p \(ShellQuote.quote(prompt + "\n")) bash -c \(s)"
        }
        return "\(run) 2>&1; echo \"@@exit $?\""
    }

    /// Runs `script` as root and streams its output. Throws `SudoError.wrongPassword` if sudo asks twice.
    /// `input` lines reach the script's stdin (after sudo has its password) — for secrets the script reads
    /// with `read -r`, so they never show up in a command line.
    public static func run(
        _ script: String, on shell: any ChannelShell, access: SudoAccess, password: String?, input: [String] = []
    ) -> AsyncThrowingStream<RootLine, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard access != .unavailable else { throw SudoError.unavailable }
                    let channel = try await shell.openChannel(command(script, access: access))
                    defer { channel.close() }
                    if access != .password { for line in input { try await channel.send(line) } }
                    var prompts = 0
                    var ended = false
                    for try await line in channel.lines {
                        if line.hasSuffix(prompt) {
                            prompts += 1
                            guard prompts == 1, let password else { throw SudoError.wrongPassword }
                            try await channel.send(password)
                            for line in input { try await channel.send(line) }
                            continue
                        }
                        if line == "Sorry, try again." { continue }
                        if line.hasPrefix("@@exit ") {
                            continuation.yield(.exit(Int32(line.dropFirst(7)) ?? 1))
                            ended = true
                            break
                        }
                        continuation.yield(.output(line))
                    }
                    if !ended { throw CLIError("The connection closed before the command finished.") }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
