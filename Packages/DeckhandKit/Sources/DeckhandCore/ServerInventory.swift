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
