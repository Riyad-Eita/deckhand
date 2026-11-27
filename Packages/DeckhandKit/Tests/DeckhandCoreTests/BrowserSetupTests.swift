import Foundation
import Testing
@testable import DeckhandCore

@Suite struct BrowserSetupTests {
    @Test func parsesTheStatus() {
        let s = BrowserSetup.parse("""
        @@arch x86_64
        @@disk 20480
        @@node v22.11.0
        @@installed 0.0.41
        @@browser
        @@missing libnss3.so
        @@missing libgbm.so.1
        """)
        #expect(s.arch == "x86_64" && s.diskFreeMB == 20480 && s.node == "v22.11.0")
        #expect(s.installed && s.version == "0.0.41" && s.browserReady && !s.works)
        #expect(s.missingLibraries == ["libnss3.so", "libgbm.so.1"])
        let empty = BrowserSetup.parse("@@arch aarch64\n@@disk 900")
        #expect(empty.node == nil && !empty.installed && !empty.works)
        #expect(BrowserSetup.parse("@@installed \n@@works").version == nil)
    }

    @Test func screenshotOnlyForWebAddresses() {
        #expect(BrowserSetup.screenshotCommand(url: "file:///etc/passwd").contains("@@failed"))
        #expect(BrowserSetup.screenshotCommand(url: "javascript:alert(1)").contains("@@failed"))
        let cmd = BrowserSetup.screenshotCommand(url: "https://example.com/a'b")
        #expect(cmd.hasSuffix(" 'https://example.com/a'\\''b' 2>/dev/null"))
    }

    @Test func parsesTheScreenshot() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        #expect(BrowserSetup.parseScreenshot("noise\n@@png \(png.base64EncodedString())").image == png)
        #expect(BrowserSetup.parseScreenshot("@@failed net::ERR_NAME_NOT_RESOLVED").error == "net::ERR_NAME_NOT_RESOLVED")
        #expect(BrowserSetup.parseScreenshot("").error != nil)
    }

    /// The MCP server runs as a stdio process through SSH: headless, a fresh profile per chat, nothing on the network.
    @Test func mcpServerStaysLocal() {
        let c = BrowserSetup.mcpCommand
        #expect(c.contains("--headless") && c.contains("--isolated"))
        #expect(!c.contains("--port") && !c.contains("--host"))
    }

    @Test func toolImagesReachTheModels() throws {
        let img = ToolImage(mediaType: "image/png", data: Data([1, 2, 3]))
        let msg = Message(role: .user, blocks: [.toolResult(ToolResult(toolUseID: "t1", content: "shot", images: [img]))])
        let anthropic = AnthropicProvider.encode(msg).jsonString()
        #expect(anthropic.contains(#""type":"image""#) && anthropic.contains("AQID"))
        let openai = OpenAIChatProvider.encode(msg).map { $0.jsonString() }.joined()
        #expect(openai.contains("data:image/png;base64,AQID"))
        // Without pictures the tool result stays a plain string.
        let plain = AnthropicProvider.encode(Message(role: .user, blocks: [.toolResult(ToolResult(toolUseID: "t", content: "x"))])).jsonString()
        #expect(plain.contains(#""content":"x""#))
    }

    /// Chats saved before pictures existed still load.
    @Test func oldToolResultsStillDecode() throws {
        let old = #"{"toolUseID":"a","content":"b","isError":false}"#
        let r = try JSONDecoder().decode(ToolResult.self, from: Data(old.utf8))
        #expect(r.images.isEmpty && r.content == "b")
    }
}
