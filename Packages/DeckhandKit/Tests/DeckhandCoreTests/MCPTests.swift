import Foundation
import Testing
@testable import DeckhandCore

@Suite struct MCPTests {
    func client() throws -> MCPClient {
        let script = try #require(Bundle.module.url(forResource: "fake_mcp_server", withExtension: "py", subdirectory: "Fixtures"))
        let channel = try LocalProcessChannel(command: "python3 -u '\(script.path)'")
        return MCPClient(name: "fake", transport: StdioMCPTransport(channel: channel))
    }

    @Test func listsAndCallsToolsOverStdio() async throws {
        let c = try client()
        let tools = try await c.tools()
        #expect(tools.map(\.name) == ["echo", "boom.fail"])
        #expect(await c.instructions == "Use echo.")
        let r = try await c.call("echo", arguments: ["text": "hi"])
        #expect(r.text == "echo: hi")
        #expect(!r.isError)
        let bad = try await c.call("boom.fail", arguments: [:])
        #expect(bad.isError)
        await c.close()
    }

    @Test func agentToolWrapsMCP() async throws {
        let c = try client()
        let tools = try await c.tools().map { MCPAgentTool(client: c, serverName: "my server", tool: $0) }
        #expect(tools.map(\.spec.name) == ["my_server__echo", "my_server__boom_fail"])
        let out = try await tools[0].execute(["text": "x"], shell: LocalShell())
        #expect(out == "echo: x")
        await #expect(throws: ToolError.self) { _ = try await tools[1].execute([:], shell: LocalShell()) }
        await c.close()
    }

    @Test func httpReplyFromSSE() throws {
        let body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\nevent: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":true}}\n\n"
        let reply = try HTTPMCPTransport.findReply(id: 3, data: Data(body.utf8), contentType: "text/event-stream")
        #expect(reply["result"]?["ok"] == true)
        let plain = try HTTPMCPTransport.findReply(id: 1, data: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8), contentType: "application/json")
        #expect(plain["id"] == 1)
    }
}
