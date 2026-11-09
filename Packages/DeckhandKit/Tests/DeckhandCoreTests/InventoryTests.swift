import Testing
@testable import DeckhandCore

@Suite struct InventoryTests {
    @Test func parsesProbeOutput() {
        let out = """
        Welcome banner noise
        @@deckhand:codex.version\tcodex-cli 0.167.0
        @@deckhand:codex.auth\tLogged in using ChatGPT
        @@deckhand:claude.version\t2.1.321 (Claude Code)
        @@deckhand:claude.auth\t{ "loggedIn": false, "authMethod": "none" }
        @@deckhand:tmux\t
        @@deckhand:screen\t/usr/bin/screen
        @@deckhand:node\tv21.7.3
        @@deckhand:os\tUbuntu 22.04.5 LTS
        """
        let inv = ServerInventory.parse(out)
        #expect(inv.codex == .init(version: "0.167.0", loggedIn: true, account: "ChatGPT"))
        #expect(inv.claudeCode == .init(version: "2.1.321", loggedIn: false, account: nil))
        #expect(inv.tmux == nil)
        #expect(inv.screen == "/usr/bin/screen")
        #expect(inv.node == "v21.7.3")
        #expect(inv.os == "Ubuntu 22.04.5 LTS")
    }

    @Test func missingCLIs() {
        let inv = ServerInventory.parse("@@deckhand:codex.version\t\n@@deckhand:codex.auth\t\n")
        #expect(!inv.codex.isInstalled)
        #expect(!inv.codex.loggedIn)
        #expect(!inv.claudeCode.isInstalled)
    }

    @Test func notLoggedInCodex() {
        #expect(!ServerInventory.parse("@@deckhand:codex.auth\tNot logged in").codex.loggedIn)
    }

    @Test func probeRunsLocally() async throws {
        let r = try await LocalShell().run(ServerInventory.probeCommand, timeout: .seconds(30))
        let inv = ServerInventory.parse(r.stdout)
        #expect(inv.os != nil, "\(r.stdout) | \(r.stderr)")
    }
}
