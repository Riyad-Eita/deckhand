import Foundation

/// An MCP server the user connected once in the app; used by the in-app agent and synced to the server CLIs.
public struct MCPConnection: Codable, Hashable, Sendable, Identifiable {
    public enum Transport: Codable, Hashable, Sendable {
        /// Streamable HTTP endpoint, optionally with a bearer token (kept in the Keychain, passed in separately).
        case http(url: String)
        /// Command that starts a stdio MCP server on the server, e.g. `npx -y @modelcontextprotocol/server-filesystem ~`.
        case stdio(command: String)
    }

    public var id: UUID
    public var name: String
    public var transport: Transport
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, transport: Transport, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.transport = transport
        self.enabled = enabled
    }

    /// Lowercase name safe for CLI configs and env vars: "My GitHub!" → "my-github".
    public var slug: String { Self.slug(name) }

    public static func slug(_ name: String) -> String {
        var out = ""
        for ch in name.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) } else if !out.hasSuffix("-") { out.append("-") }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "mcp" : String(trimmed.prefix(40))
    }

    public var tokenEnvVar: String {
        "DECKHAND_MCP_" + slug.uppercased().replacingOccurrences(of: "-", with: "_") + "_TOKEN"
    }
}

/// Builds the idempotent shell script that makes the server's Claude Code and Codex use the same MCP servers.
public enum ConnectionSync {
    public static let envFile = "~/.config/deckhand/env"
    static let manifest = "~/.config/deckhand/mcp-managed"

    /// `connections` are the enabled ones, each with its token (if any).
    public static func script(_ connections: [(MCPConnection, token: String?)]) -> String {
        var lines: [String] = [
            "set -u",
            "mkdir -p ~/.config/deckhand && chmod 700 ~/.config/deckhand",
            "touch \(envFile) \(manifest) && chmod 600 \(envFile)",
        ]
        // Load the env file from login and interactive shells (once).
        for rc in ["~/.profile", "~/.bashrc"] {
            lines.append(
                "grep -q 'config/deckhand/env' \(rc) 2>/dev/null || printf '\\n# deckhand\\n[ -f ~/.config/deckhand/env ] && . ~/.config/deckhand/env\\n' >> \(rc)")
        }
        // Tokens for Codex (it reads bearer tokens from env vars).
        let exports = connections.compactMap { c, token -> String? in
            guard case .http = c.transport, let token, !token.isEmpty else { return nil }
            return "export \(c.tokenEnvVar)=\(ShellQuote.quote(token))"
        }
        lines.append("printf '%s\\n' \(exports.map(ShellQuote.quote).joined(separator: " ")) > \(envFile)")
        lines.append(". \(envFile)")

        // Remove what we added before and is gone now.
        let names = connections.map(\.0.slug)
        lines.append("for old in $(cat \(manifest)); do case \" \(names.joined(separator: " ")) \" in *\" $old \"*) ;; *)")
        lines.append("  command -v claude >/dev/null 2>&1 && claude mcp remove -s user \"$old\" >/dev/null 2>&1")
        lines.append("  command -v codex >/dev/null 2>&1 && codex mcp remove \"$old\" >/dev/null 2>&1 ;; esac; done")

        for (c, token) in connections {
            let name = ShellQuote.quote(c.slug)
            var claude: String
            var codex: String
            switch c.transport {
            case .http(let url):
                claude = "claude mcp add -s user --transport http \(name) \(ShellQuote.quote(url))"
                if let token, !token.isEmpty { claude += " -H \(ShellQuote.quote("Authorization: Bearer \(token)"))" }
                codex = "codex mcp add \(name) --url \(ShellQuote.quote(url))"
                if let token, !token.isEmpty { codex += " --bearer-token-env-var \(c.tokenEnvVar)" }
            case .stdio(let command):
                claude = "claude mcp add -s user \(name) -- bash -lc \(ShellQuote.quote(command))"
                codex = "codex mcp add \(name) -- bash -lc \(ShellQuote.quote(command))"
            }
            lines.append("if command -v claude >/dev/null 2>&1; then claude mcp remove -s user \(name) >/dev/null 2>&1; \(claude) >/dev/null 2>&1 && echo \"claude ok \(c.slug)\" || echo \"claude failed \(c.slug)\"; fi")
            lines.append("if command -v codex >/dev/null 2>&1; then codex mcp remove \(name) >/dev/null 2>&1; \(codex) >/dev/null 2>&1 && echo \"codex ok \(c.slug)\" || echo \"codex failed \(c.slug)\"; fi")
        }
        lines.append("printf '%s\\n' \(names.map(ShellQuote.quote).joined(separator: " ")) | grep -v '^$' > \(manifest) || true")
        return lines.joined(separator: "\n")
    }

    /// Parses the script's `claude ok x` / `codex failed y` lines.
    public static func results(_ output: String) -> [String: [ServerCLI: Bool]] {
        var out: [String: [ServerCLI: Bool]] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 3 else { continue }
            let cli: ServerCLI? = parts[0] == "claude" ? .claudeCode : parts[0] == "codex" ? .codex : nil
            guard let cli else { continue }
            out[String(parts[2]), default: [:]][cli] = parts[1] == "ok"
        }
        return out
    }
}
