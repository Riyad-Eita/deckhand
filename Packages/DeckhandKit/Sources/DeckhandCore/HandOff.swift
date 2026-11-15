import Foundation

/// "Continue on a computer": the one command that opens a running Claude Code or Codex session in a terminal on
/// another machine — an SSH login to the server (through the jump host if there is one) that resumes the session
/// in its folder. No secret is part of it; the computer signs in with its own key or password.
public enum HandOff {
    public struct Endpoint: Equatable, Sendable {
        public var host: String, port: Int, user: String
        public init(host: String, port: Int = 22, user: String) { self.host = host; self.port = port; self.user = user }
        var target: String { "\(user)@\(host)" + (port == 22 ? "" : ":\(port)") }
    }

    /// The command on the server: change to the task's folder, resume the session.
    public static func remoteCommand(cli: ServerCLI, directory: String, sessionID: String) -> String {
        let resume = switch cli {
        case .claudeCode: "claude --resume \(word(sessionID))"
        case .codex: "codex resume \(word(sessionID))"
        }
        return "cd \(folder(directory)) && \(resume)"
    }

    /// The full command for a terminal on another computer.
    public static func command(cli: ServerCLI, server: Endpoint, jump: Endpoint? = nil, directory: String, sessionID: String) -> String {
        var parts = ["ssh", "-t"]
        if server.port != 22 { parts += ["-p", String(server.port)] }
        if let jump { parts += ["-J", jump.target] }
        parts.append("\(server.user)@\(server.host)")
        parts.append(ShellQuote.quote(remoteCommand(cli: cli, directory: directory, sessionID: sessionID)))
        return parts.joined(separator: " ")
    }

    /// `~` stays unquoted so the server's shell expands it; the rest is quoted.
    static func folder(_ dir: String) -> String {
        let d = dir.trimmingCharacters(in: .whitespaces)
        if d.isEmpty || d == "~" { return "~" }
        if d.hasPrefix("~/") { return "~/" + word(String(d.dropFirst(2))) }
        return word(d)
    }

    /// Quoted only when the shell would read it differently, so the command stays readable.
    static func word(_ s: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/+:@%,=")
        return !s.isEmpty && s.unicodeScalars.allSatisfy(plain.contains) ? s : ShellQuote.quote(s)
    }
}
