import Foundation

/// Signing a server CLI in from the phone: the CLI runs its own login in a hidden terminal on the server,
/// the app shows the provider's real sign-in page and feeds the result back.
public enum CLILoginEvent: Sendable, Equatable {
    /// The sign-in page to show.
    case openURL(URL)
    /// Device-code flows (Codex): the code the user enters on the page.
    case deviceCode(String)
    /// The CLI waits for the authorization code (Claude Code).
    case waitingForCode
    case succeeded
    case failed(String)
}

public struct CLILoginParser: Sendable {
    public let cli: ServerCLI
    private var buffer = ""
    private var sentURL = false
    private var sentCode = false
    private var sentWaiting = false

    public init(cli: ServerCLI) { self.cli = cli }

    /// The command to type into the hidden terminal. `exec` makes the terminal close when the CLI exits.
    public var command: String {
        switch cli {
        case .claudeCode: "exec claude auth login"
        case .codex: "exec codex login --device-auth"
        }
    }

    public mutating func feed(_ chunk: String) -> [CLILoginEvent] {
        buffer += Self.stripEscapes(chunk)
        if buffer.count > 20_000 { buffer = String(buffer.suffix(10_000)) }
        var events: [CLILoginEvent] = []
        if !sentURL, let url = firstURL() {
            sentURL = true
            events.append(.openURL(url))
        }
        if cli == .codex, !sentCode, let code = Self.firstMatch(#"\b[A-Z0-9]{4}-[A-Z0-9]{4,6}\b"#, in: buffer) {
            sentCode = true
            events.append(.deviceCode(code))
        }
        if cli == .claudeCode, !sentWaiting, buffer.localizedCaseInsensitiveContains("paste code") {
            sentWaiting = true
            events.append(.waitingForCode)
        }
        let lower = buffer.lowercased()
        if lower.contains("login successful") || lower.contains("successfully logged in") || lower.contains("logged in as") {
            events.append(.succeeded)
            buffer = ""
        } else if let err = ["invalid code", "oauth error", "login failed", "authorization failed", "expired"].first(where: lower.contains) {
            events.append(.failed(err))
            buffer = ""
        }
        return events
    }

    private func firstURL() -> URL? {
        let pattern = cli == .claudeCode
            ? #"https://(?:claude\.com|claude\.ai|console\.anthropic\.com)/[^\s\u0007\u001b\]]+"#
            : #"https://auth\.openai\.com/[^\s\u0007\u001b\]]+"#
        guard let s = Self.firstMatch(pattern, in: buffer) else { return nil }
        // OSC 8 hyperlinks print the URL twice back to back; keep the first copy.
        let trimmed = s.components(separatedBy: "https://").dropFirst().first.map { "https://" + $0 } ?? s
        return URL(string: trimmed)
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[r])
    }

    /// Removes CSI sequences and OSC sequences (ESC ] … BEL / ESC \).
    public static func stripEscapes(_ s: String) -> String {
        var out = s.replacingOccurrences(of: #"\u001b\][^\u0007\u001b]*(\u0007|\u001b\\)"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\u001b\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        return out.replacingOccurrences(of: "\r", with: "")
    }
}

public enum ClaudeOAuth {
    /// Whether copied text looks like the code the callback page shows (`code#state`).
    public static func looksLikeCode(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.range(of: #"^[A-Za-z0-9_\-]{16,}#[A-Za-z0-9_\-]{8,}$"#, options: .regularExpression) != nil
    }

    /// The text Claude Code expects at "Paste code here": `code#state` from the callback page's URL.
    public static func code(fromCallback url: URL) -> String? {
        guard let host = url.host, ["platform.claude.com", "console.anthropic.com", "claude.ai", "claude.com"].contains(host),
              url.path.contains("/oauth/code/callback"),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { return nil }
        let state = items.first(where: { $0.name == "state" })?.value
        return state.map { "\(code)#\($0)" } ?? code
    }
}
