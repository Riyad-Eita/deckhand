import Foundation
import Testing
@testable import DeckhandCore

@Suite struct CLISessionsTests {
    func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func list() {
        let out = """
        @@session\tclaudeCode\t3f2a\t1763064000\t/home/me/shop\tFix the shop's 502
        @@session\tcodex\t7d1e\t1763067600\t/home/me/api\tAdd a health endpoint
        @@session\tcodex\t8e2f\t1763060000\t/home/me/shop\tWhy is it \\"slow\\"?
        @@session\tclaudeCode\t\t1763060000\t/x\tbroken
        junk
        """
        let sessions = CLISessions.parseList(out)
        #expect(sessions.map(\.id) == ["7d1e", "3f2a", "8e2f"])
        #expect(sessions[2].title == #"Why is it "slow"?"#)
        let groups = CLISessions.byFolder(sessions)
        #expect(groups.map(\.folder) == ["/home/me/api", "/home/me/shop"])
        #expect(groups[1].sessions.map(\.id) == ["3f2a", "8e2f"])
    }

    @Test func claudeTranscript() throws {
        let lines = try fixture("claude-session").split(separator: "\n").filter { $0.contains(#""type":"user""#) || $0.contains(#""type":"assistant""#) }
        let messages = CLISessions.parseTranscript(cli: .claudeCode, lines.joined(separator: "\n"))
        #expect(messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(messages[0].text == "Why does the shop return 502?")
        #expect(messages[1].text == "Let me check PHP-FPM.")
        #expect(messages[1].toolCalls.first?.name == "run_command")
        #expect(messages[1].toolCalls.first?.input["command"]?.stringValue == "systemctl status php8.3-fpm")
        #expect(messages[3].text == "PHP-FPM is down; restart it.")
        #expect(!messages.contains { $0.text.contains("sidechain") || $0.text.contains("hidden") })
    }

    @Test func codexTranscript() throws {
        let lines = try fixture("codex-session").split(separator: "\n").filter { $0.contains(#""type":"response_item""#) }
        let messages = CLISessions.parseTranscript(cli: .codex, lines.joined(separator: "\n"))
        #expect(messages.first?.text == "Add a health endpoint")
        #expect(messages[1].toolCalls.first?.input["command"]?.stringValue == "ls src")
        if case .toolResult(let r)? = messages[2].blocks.first { #expect(r.content == "main.py\nroutes.py") } else { Issue.record("no result") }
        #expect(messages.last?.text == "Added GET /health.")
        #expect(!messages.contains { $0.text.contains("environment_context") })
    }

    @Test func commandsOnlyTakeSafeIDs() {
        let hostile = CLISessions.transcriptCommand(cli: .claudeCode, id: "3f2a; rm -rf ~")
        #expect(hostile.contains("/3f2arm-rf.jsonl"))
        #expect(!hostile.contains("; rm"))
        #expect(CLISessions.transcriptCommand(cli: .codex, id: "7d1e").contains("*7d1e.jsonl"))
    }
}
