import Foundation

/// What is installed on a server and whether the CLIs are logged in. Gathered with one command.
public struct ServerInventory: Sendable, Hashable {
    public struct CLIState: Sendable, Hashable {
        public var version: String?
        public var loggedIn: Bool
        public var account: String?
        public var isInstalled: Bool { version != nil }
    }

    public var codex: CLIState
    public var claudeCode: CLIState
    public var tmux: String?
    public var screen: String?
    public var node: String?
    public var os: String?

    public func state(for cli: ServerCLI) -> CLIState {
        cli == .codex ? codex : claudeCode
    }

    static let marker = "@@deckhand:"

    /// Prints `@@deckhand:key<TAB>value` lines; never fails as a whole.
    public static let probeCommand = """
    p() { printf '\(marker)%s\\t%s\\n' "$1" "$(printf '%s' "$2" | tr '\\n' ' ')"; }
    p codex.version "$(command -v codex >/dev/null 2>&1 && codex --version 2>/dev/null | head -1)"
    p codex.auth "$(command -v codex >/dev/null 2>&1 && codex login status 2>&1 | head -3)"
    p claude.version "$(command -v claude >/dev/null 2>&1 && claude --version 2>/dev/null | head -1)"
    p claude.auth "$(command -v claude >/dev/null 2>&1 && claude auth status --json 2>/dev/null)"
    p tmux "$(tmux -V 2>/dev/null)"
    p node "$(node --version 2>/dev/null)"
    p screen "$(command -v screen 2>/dev/null)"
    p os "$( ( [ -r /etc/os-release ] && . /etc/os-release && echo "$PRETTY_NAME" ) || uname -sr)"
    """

    public static func parse(_ output: String) -> ServerInventory {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") where line.hasPrefix(marker) {
            let body = line.dropFirst(marker.count)
            guard let tab = body.firstIndex(of: "\t") else { continue }
            let value = body[body.index(after: tab)...].trimmingCharacters(in: .whitespaces)
            values[String(body[..<tab])] = value.isEmpty ? nil : value
        }

        let codexAuth = values["codex.auth"] ?? ""
        let codexLoggedIn = codexAuth.localizedCaseInsensitiveContains("logged in")
            && !codexAuth.localizedCaseInsensitiveContains("not logged in")
        var codexAccount: String?
        if let range = codexAuth.range(of: "using ", options: .caseInsensitive) {
            codexAccount = String(codexAuth[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }

        var claudeLoggedIn = false
        var claudeAccount: String?
        if let raw = values["claude.auth"], let json = try? JSONValue.parse(raw) {
            claudeLoggedIn = json["loggedIn"]?.boolValue ?? false
            claudeAccount = json["email"]?.stringValue ?? json["account"]?["email"]?.stringValue
                ?? (claudeLoggedIn ? json["authMethod"]?.stringValue : nil)
        }

        return ServerInventory(
            codex: CLIState(version: values["codex.version"].map(Self.versionNumber), loggedIn: codexLoggedIn, account: codexAccount),
            claudeCode: CLIState(version: values["claude.version"].map(Self.versionNumber), loggedIn: claudeLoggedIn, account: claudeAccount),
            tmux: values["tmux"],
            screen: values["screen"],
            node: values["node"],
            os: values["os"])
    }

    /// "codex-cli 0.167.0" → "0.167.0", "2.1.321 (Claude Code)" → "2.1.321"
    static func versionNumber(_ s: String) -> String {
        s.split(separator: " ").first { $0.first?.isNumber == true }.map(String.init) ?? s
    }
}

extension ServerCLI {
    /// Interactive login, meant to run in the terminal so the user can open the link and enter codes.
    public var loginCommand: String {
        switch self {
        case .codex: "codex login --device-auth"
        case .claudeCode: "claude auth login"
        }
    }
}

/// A terminal session that survives disconnects: tmux if the server has it, otherwise GNU screen.
public enum PersistentSession {
    public static let name = "deckhand"

    /// The kept session for terminal tab `tab` (1-based): "deckhand", "deckhand-2", …
    public static func name(tab: Int) -> String { tab <= 1 ? name : "\(name)-\(tab)" }

    /// First line to type into a fresh login shell; replaces the shell with the multiplexer.
    /// Falls back to the plain shell when neither is installed. In tmux the window title follows the running
    /// program (set for this session only, not globally), so the app can name the tab.
    public static func attachCommand(tab: Int = 1) -> String {
        let n = name(tab: tab)
        return "if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s \(n) \\; set-option set-titles on \\; "
            + "set-option set-titles-string '#{pane_current_command}'; "
            + "elif command -v screen >/dev/null 2>&1; then exec screen -xRR -S \(n); fi"
    }

    public static let attachCommand = attachCommand(tab: 1)

    /// Ends a tab's kept session (when its tab is closed).
    public static func endCommand(tab: Int) -> String {
        let n = name(tab: tab)
        return "tmux kill-session -t \(n) 2>/dev/null; screen -S \(n) -X quit 2>/dev/null; true"
    }
}

/// Terminal tabs: numbers, titles.
public enum TerminalTabs {
    /// The lowest tab number not in use.
    public static func next(after tabs: [Int]) -> Int {
        var n = 1
        while tabs.contains(n) { n += 1 }
        return n
    }

    /// A short tab title from the terminal title: "bash"/"zsh" and "user@host: dir" become the folder; programs stay.
    public static func title(_ raw: String?, tab: Int) -> String {
        let fallback = String(localized: "Shell \(tab)")
        guard var t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return fallback }
        if let colon = t.range(of: ": "), t[..<colon.lowerBound].contains("@") { t = String(t[colon.upperBound...]) }
        if ["bash", "zsh", "sh", "fish", "-bash", "-zsh"].contains(t) { return fallback }
        return t.count > 24 ? String(t.prefix(23)) + "…" : t
    }
}
