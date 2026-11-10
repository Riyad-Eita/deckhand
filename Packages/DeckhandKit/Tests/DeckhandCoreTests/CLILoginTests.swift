import Foundation
import Testing
@testable import DeckhandCore

@Suite struct CLILoginTests {
    @Test func claudeOutputYieldsURLThenWaits() {
        var p = CLILoginParser(cli: .claudeCode)
        let url = "https://claude.com/cai/oauth/authorize?code=true&client_id=abc&state=XYZ"
        let out = "Opening browser to sign in…\r\nIf the browser didn't open, visit: \u{1b}]8;;\(url)\u{07}\(url)\u{1b}]8;;\u{07}\r\n"
        #expect(p.feed(out) == [.openURL(URL(string: url)!)])
        #expect(p.feed("Paste code here if prompted > ") == [.waitingForCode])
        #expect(p.feed("Login successful.\r\n") == [.succeeded])
    }

    @Test func codexDeviceCode() {
        var p = CLILoginParser(cli: .codex)
        let ev = p.feed("""
        1. Open this link in your browser and sign in to your account
           \u{1b}[94mhttps://auth.openai.com/codex/device\u{1b}[0m
        2. Enter this one-time code (expires in 15 minutes)
           \u{1b}[94mA108-2HS7C\u{1b}[0m
        """)
        #expect(ev == [.openURL(URL(string: "https://auth.openai.com/codex/device")!), .deviceCode("A108-2HS7C")])
        #expect(p.feed("Successfully logged in\n") == [.succeeded])
    }

    @Test func callbackCode() {
        let u = URL(string: "https://platform.claude.com/oauth/code/callback?code=abc123&state=XYZ")!
        #expect(ClaudeOAuth.code(fromCallback: u) == "abc123#XYZ")
        #expect(ClaudeOAuth.code(fromCallback: URL(string: "https://claude.com/login")!) == nil)
        #expect(ClaudeOAuth.code(fromCallback: URL(string: "https://evil.example/oauth/code/callback?code=x")!) == nil)
        #expect(ClaudeOAuth.looksLikeCode("kJ8s_2LmQpX0aBcD9eFgHiJk#30hHh1d4lmo6IVo"))
        #expect(!ClaudeOAuth.looksLikeCode("hello world"))
    }
}
