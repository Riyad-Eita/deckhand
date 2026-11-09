import Foundation
import Testing
@testable import DeckhandCore

@Suite struct ConnectionSyncTests {
    @Test func slugs() {
        #expect(MCPConnection.slug("My GitHub!") == "my-github")
        #expect(MCPConnection.slug("  ") == "mcp")
        #expect(MCPConnection(name: "Deep Wiki", transport: .http(url: "x")).tokenEnvVar == "DECKHAND_MCP_DEEP_WIKI_TOKEN")
    }

    @Test func scriptMentionsBothCLIs() {
        let gh = MCPConnection(name: "GitHub", transport: .http(url: "https://api.githubcopilot.com/mcp/"))
        let fs = MCPConnection(name: "files", transport: .stdio(command: "npx -y @modelcontextprotocol/server-filesystem ~"))
        let s = ConnectionSync.script([(gh, "tok'en"), (fs, nil)])
        #expect(s.contains("claude mcp add -s user --transport http 'github' 'https://api.githubcopilot.com/mcp/' -H 'Authorization: Bearer tok'\\''en'"))
        #expect(s.contains("codex mcp add 'github' --url 'https://api.githubcopilot.com/mcp/' --bearer-token-env-var DECKHAND_MCP_GITHUB_TOKEN"))
        #expect(s.contains("codex mcp add 'files' -- bash -lc 'npx -y @modelcontextprotocol/server-filesystem ~'"))
    }

    /// Runs the script in a fake HOME with stub `claude`/`codex` that log their arguments.
    @Test func scriptRunsAndIsIdempotent() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "dh-home-\(UUID().uuidString.prefix(6))").path
        let bin = home + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        for name in ["claude", "codex"] {
            let stub = "#!/bin/sh\necho \"$*\" >> \"$HOME/\(name).log\"\n"
            FileManager.default.createFile(atPath: "\(bin)/\(name)", contents: Data(stub.utf8), attributes: [.posixPermissions: 0o755])
        }
        let gh = MCPConnection(name: "GitHub", transport: .http(url: "https://example.com/mcp"))
        let wiki = MCPConnection(name: "wiki", transport: .http(url: "https://w.example/mcp"))
        func run(_ conns: [(MCPConnection, String?)]) async throws -> CommandResult {
            try await LocalShell().run("HOME='\(home)' PATH='\(bin):/usr/bin:/bin' sh -c \(ShellQuote.quote(ConnectionSync.script(conns)))", timeout: .seconds(30))
        }
        let first = try await run([(gh, "secret"), (wiki, nil)])
        #expect(ConnectionSync.results(first.stdout) == ["github": [.claudeCode: true, .codex: true], "wiki": [.claudeCode: true, .codex: true]])
        let env = try String(contentsOfFile: home + "/.config/deckhand/env", encoding: .utf8)
        #expect(env == "export DECKHAND_MCP_GITHUB_TOKEN='secret'\n")
        let attrs = try FileManager.default.attributesOfItem(atPath: home + "/.config/deckhand/env")
        #expect((attrs[.posixPermissions] as? Int) == 0o600)

        // Second run without "wiki": it gets removed, profile line is not duplicated.
        _ = try await run([(gh, "secret")])
        let codexLog = try String(contentsOfFile: home + "/codex.log", encoding: .utf8)
        #expect(codexLog.contains("mcp remove wiki"))
        let profile = try String(contentsOfFile: home + "/.profile", encoding: .utf8)
        #expect(profile.components(separatedBy: "# deckhand").count == 2)
        let manifest = try String(contentsOfFile: home + "/.config/deckhand/mcp-managed", encoding: .utf8)
        #expect(manifest == "github\n")
    }
}
