import Foundation
import Testing
@testable import DeckhandCore

@Suite(.serialized) struct ServerMemoryTests {
    func home() throws -> String {
        let h = FileManager.default.temporaryDirectory.appending(path: "mem-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: h + "/.claude", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: h + "/.codex", withIntermediateDirectories: true)
        try "# My rules\nBe brief.\n".write(toFile: h + "/.claude/CLAUDE.md", atomically: true, encoding: .utf8)
        return h
    }

    func sh(_ h: String, _ cmd: String) async throws -> String {
        try await LocalShell().run("HOME='\(h)' PATH=/usr/bin:/bin /bin/sh -c \(ShellQuote.quote(cmd))", timeout: .seconds(10)).stdout
    }

    @Test func writeAppendReadDelete() async throws {
        let h = try home()
        #expect(try await sh(h, ServerMemory.appendCommand("nginx config lives in /etc/nginx/sites-enabled/app", date: Date(timeIntervalSince1970: 1_794_000_000))).contains("@@ok"))
        _ = try await sh(h, ServerMemory.appendCommand("Use `systemctl --user` for the bot's service — it's 'special'"))
        var notes = try await sh(h, ServerMemory.readCommand)
        #expect(notes.hasPrefix("# Server notes"))
        #expect(notes.contains("- nginx config lives in /etc/nginx/sites-enabled/app (2026-11-06)"))
        #expect(notes.contains("it's 'special'"))
        _ = try await sh(h, ServerMemory.writeCommand("Edited by hand: $HOME and \"quotes\"\n"))
        notes = try await sh(h, ServerMemory.readCommand)
        #expect(notes == "Edited by hand: $HOME and \"quotes\"\n")
        _ = try await sh(h, ServerMemory.deleteCommand)
        #expect(try await sh(h, ServerMemory.readCommand).isEmpty)
    }

    @Test func connectsTheCLIsOnce() async throws {
        let h = try home()
        _ = try await sh(h, ServerMemory.connectCLIsCommand)
        let out = try await sh(h, ServerMemory.connectCLIsCommand)   // twice: still one block
        #expect(out.contains("@@claude") && out.contains("@@codex"))
        let claude = try String(contentsOfFile: h + "/.claude/CLAUDE.md", encoding: .utf8)
        #expect(claude.hasPrefix("# My rules\nBe brief.\n"))
        #expect(claude.components(separatedBy: "<!-- deckhand:memory -->").count == 2)
        #expect(claude.contains("@~/.deckhand/memory.md"))
        #expect(try String(contentsOfFile: h + "/.codex/AGENTS.md", encoding: .utf8).contains("Read ~/.deckhand/memory.md"))
        _ = try await sh(h, ServerMemory.disconnectCLIsCommand)
        let after = try String(contentsOfFile: h + "/.claude/CLAUDE.md", encoding: .utf8)
        #expect(!after.contains("deckhand:memory") && after.contains("Be brief."))
    }

    @Test func promptKeepsTheNewestNotes() {
        let long = String(repeating: "x", count: 9_000) + "NEWEST"
        #expect(ServerMemory.promptSection(long).hasSuffix("NEWEST"))
        #expect(ServerMemory.promptSection("").contains("No notes yet"))
    }
}
