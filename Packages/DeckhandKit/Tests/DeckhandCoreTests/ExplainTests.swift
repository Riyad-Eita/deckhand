import Foundation
import Testing
@testable import DeckhandCore

struct ExplainTests {
    @Test func colourCodesAreRemoved() {
        let raw = "\u{1B}[31mERROR\u{1B}[0m: connect() failed\r\n\u{1B}]0;title\u{07}\u{1B}[?25lnext"
        #expect(Explain.stripANSI(raw) == "ERROR: connect() failed\nnext")
    }

    @Test func longOutputKeepsTheEnd() {
        let text = String(repeating: "noise\n", count: 3_000) + "FATAL: disk full"
        let p = Explain.prompt(text, context: "the log nginx")
        #expect(p.hasPrefix("Where it comes from: the log nginx\nOutput:\n…") && p.hasSuffix("FATAL: disk full"))
        #expect(p.count < 6_200)
        #expect(Explain.tail("a\n\nb\nc\n", lines: 2) == "b\nc")
    }

    @Test func fixPromptCarriesTheExplanation() {
        let f = Explain.fixPrompt("502 Bad Gateway", explanation: "nginx can't reach the app.", context: "the terminal")
        #expect(f.hasPrefix("Fix this problem (the terminal).") && f.contains("502 Bad Gateway") && f.hasSuffix("nginx can't reach the app."))
    }

    @Test func titlesAreCleaned() {
        #expect(Explain.cleanTitle("\"Fix the nginx 502 error.\"\nmore") == "Fix the nginx 502 error")
        #expect(Explain.cleanTitle("Title: Upgrade Node") == "Upgrade Node")
    }

    @Test func oneCallUsesNoTools() async throws {
        let provider = ScriptedProvider([[.completed(Message(role: .assistant, blocks: [.text("It means X.")]), .endTurn, Usage())]])
        #expect(try await provider.complete(system: Explain.instructions, prompt: Explain.prompt("x")) == "It means X.")
        #expect(provider.requests[0].tools.isEmpty && provider.requests[0].system.contains("five"))
    }
}
