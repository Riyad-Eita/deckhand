import Foundation

/// Connects a server to GitHub with the official GitHub CLI's device sign-in: `gh` gets the login,
/// git uses it through `gh auth setup-git`, and the agents get GitHub's MCP server with the same token.
/// No root needed: if `gh` is missing it goes to `~/.local/bin`.
public enum GitHubConnect {
    public static let deviceURL = URL(string: "https://github.com/login/device")!
    public static let mcpURL = "https://api.githubcopilot.com/mcp/"

    /// `gh` from the PATH, or the copy Deckhand installs.
    static let gh = #"GH=$(command -v gh 2>/dev/null || echo "$HOME/.local/bin/gh")"#

    public enum State: Equatable, Sendable {
        case notInstalled
        case signedOut
        case signedIn(account: String)
    }

    public static let statusCommand = """
    \(gh)
    if [ ! -x "$GH" ]; then echo '@@nogh'; exit 0; fi
    "$GH" auth status --hostname github.com 2>&1; true
    """

    public static func parseStatus(_ output: String) -> State {
        if output.contains("@@nogh") { return .notInstalled }
        // "Logged in to github.com account octocat (…)" (new) or "Logged in to github.com as octocat (…)" (old)
        for pattern in [#"Logged in to github\.com account ([A-Za-z0-9-]+)"#, #"Logged in to github\.com as ([A-Za-z0-9-]+)"#] {
            if let r = output.range(of: pattern, options: .regularExpression) {
                let account = output[r].split(separator: " ").last.map(String.init) ?? ""
                if !output.contains("Failed to log in") { return .signedIn(account: account) }
            }
        }
        return .signedOut
    }

    /// Installs the latest GitHub CLI release into ~/.local/bin (Linux, x86_64 / arm64 / armv6).
    public static let installCommand = #"""
    set -e
    case "$(uname -m)" in x86_64|amd64) A=amd64;; aarch64|arm64) A=arm64;; armv6l|armv7l) A=armv6;; *) echo "Unsupported CPU $(uname -m)"; exit 1;; esac
    V=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')
    [ -n "$V" ] || { echo "Couldn't find the latest GitHub CLI release."; exit 1; }
    T=$(mktemp -d); curl -fsSL "https://github.com/cli/cli/releases/download/v$V/gh_${V}_linux_${A}.tar.gz" | tar -xz -C "$T"
    mkdir -p "$HOME/.local/bin"; mv "$T/gh_${V}_linux_${A}/bin/gh" "$HOME/.local/bin/gh"; rm -rf "$T"
    "$HOME/.local/bin/gh" --version | head -n 1
    """#

    /// Device sign-in, then git credentials. Prints the code and URL, waits for the user, ends with `@@ok`.
    public static let loginCommand = """
    \(gh)
    GH_PROMPT_DISABLED=1 "$GH" auth login --hostname github.com --git-protocol https --web --skip-ssh-key --scopes workflow </dev/null 2>&1 \
      && "$GH" auth setup-git --hostname github.com 2>&1 && echo '@@ok' || echo '@@failed'
    """

    /// The token for the MCP connection. Only ever read into the app's Keychain.
    public static let tokenCommand = """
    \(gh)
    "$GH" auth token --hostname github.com 2>/dev/null
    """

    /// Signs out on the server and removes the git credential helper.
    public static let logoutCommand = """
    \(gh)
    [ -x "$GH" ] && "$GH" auth logout --hostname github.com 2>&1 </dev/null
    git config --global --unset-all credential.https://github.com.helper 2>/dev/null
    git config --global --unset-all credential.https://gist.github.com.helper 2>/dev/null
    echo '@@ok'
    """

    public enum LoginEvent: Equatable, Sendable {
        case code(String)
        case succeeded
        case failed(String)
    }

    /// Reads the login's output lines.
    public static func event(_ line: String) -> LoginEvent? {
        if line == "@@ok" { return .succeeded }
        if line == "@@failed" { return .failed("GitHub sign-in didn't finish.") }
        if line.localizedCaseInsensitiveContains("one-time code"),
           let r = line.range(of: #"\b[A-Z0-9]{4}-[A-Z0-9]{4}\b"#, options: .regularExpression) {
            return .code(String(line[r]))
        }
        return nil
    }
}
