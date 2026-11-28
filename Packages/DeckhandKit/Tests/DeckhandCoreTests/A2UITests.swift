import Foundation
import Testing
@testable import DeckhandCore

@Suite struct A2UITests {
    let card: JSONValue = ["messages": [["version": "1.0", "createSurface": [
        "surfaceId": "svc-1",
        "components": [
            ["id": "root", "component": "Card", "child": "t"],
            ["id": "t", "component": "Text", "text": "nginx is failed"],
        ],
    ]]]]

    @Test func acceptsAViewAndFillsInTheCatalog() throws {
        let messages = A2UI.normalize(A2UI.messages(card))
        #expect(A2UI.check(messages) == nil)
        #expect(messages[0]["createSurface"]?["catalogId"]?.stringValue == A2UI.basicCatalogID)
        #expect(A2UI.createdSurfaces(card) == ["svc-1"])
        // A missing version is filled in too.
        let bare: JSONValue = ["messages": [["deleteSurface": ["surfaceId": "svc-1"]]]]
        #expect(A2UI.check(A2UI.messages(bare)) == nil)
    }

    @Test func explainsWhatToFix() {
        func problem(_ m: JSONValue) -> String { A2UI.check(A2UI.messages(["messages": [m]])) ?? "" }
        #expect(problem(["version": "0.9", "deleteSurface": ["surfaceId": "a"]]).contains("\"1.0\""))
        #expect(problem(["version": "1.0", "deleteSurface": ["surfaceId": "a"], "updateDataModel": ["surfaceId": "a"]]).contains("exactly one"))
        #expect(problem(["version": "1.0", "callRendererFunction": ["surfaceId": "a"]]).contains("exactly one"))
        #expect(problem(["version": "1.0", "deleteSurface": ["surfaceId": "a b/../"]]).contains("surfaceId"))
        #expect(problem(["version": "1.0", "createSurface": ["surfaceId": "a", "catalogId": "https://evil.example/catalog.json"]]).contains("basic catalog"))
        #expect(problem(["version": "1.0", "createSurface": ["surfaceId": "a", "components": [["id": "x", "component": "Text", "text": "hi"]]]]).contains("\"root\""))
        #expect(problem(["version": "1.0", "updateComponents": ["surfaceId": "a", "components": [["id": "root", "component": "WebView"]]]]).contains("isn't available"))
        #expect(problem(["version": "1.0", "updateComponents": ["surfaceId": "a", "components": [["id": "main-col", "component": "Column", "children": []]]]]).contains("main_col"))
        #expect(A2UI.check([]) != nil)
        let huge = JSONValue.array((0..<400).map { ["id": .string("c\($0)"), "component": "Text", "text": "x"] })
        #expect(problem(["version": "1.0", "updateComponents": ["surfaceId": "a", "components": huge]]).contains("Too many components"))
    }

    @Test func toolChecksThenAsksTheRenderer() async throws {
        let ok = ShowUITool()
        #expect(ok.isReadOnly)
        #expect(try await ok.execute(card, shell: LocalShell()).contains("svc-1"))
        let refusing = ShowUITool { _ in "unknown property" }
        await #expect(throws: ToolError.self) { _ = try await refusing.execute(card, shell: LocalShell()) }
        await #expect(throws: ToolError.self) { _ = try await ok.execute(["messages": []], shell: LocalShell()) }
        #expect(ok.spec.name == "show_ui" && ok.spec.description.contains("createSurface"))
    }

    @Test func aTapBecomesAReadableMessageWithTheActionForTheAgent() throws {
        let action = A2UI.Action(name: "restart", surfaceId: "svc-1", sourceComponentId: "b1", userMessage: "Restart nginx", context: ["unit": "nginx"])
        let text = A2UI.message(for: action)
        let shown = A2UI.displayText(text)
        #expect(shown.text == "Restart nginx" && shown.isAction)
        let block = try #require(text.components(separatedBy: "```\(A2UI.actionFence)\n").last?.components(separatedBy: "\n```").first)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(block.utf8))
        #expect(json["version"]?.stringValue == "1.0")
        #expect(json["action"]?["name"]?.stringValue == "restart")
        #expect(json["action"]?["context"]?["unit"]?.stringValue == "nginx")
        #expect(A2UI.Action(name: "ok", surfaceId: "s").display.contains("ok"))
        #expect(A2UI.displayText("plain text") == ("plain text", false))
    }

    /// A session (Claude Code, Codex) writes views as ```a2ui blocks; the chat draws them in place of the block.
    @Test func replyBlocksBecomeViews() throws {
        let view = #"{"messages":[{"version":"1.0","createSurface":{"surfaceId":"disk-1","components":[{"id":"root","component":"Text","text":"41%"}]}}]}"#
        let reply = "Here is the disk:\n\n```a2ui\n\(view)\n```\n\nAnything else?"
        #expect(A2UI.segments(reply) == [.text("Here is the disk:"), .view(view), .text("Anything else?")])
        #expect(A2UI.viewBlocks(reply) == [view])
        let messages = try A2UI.parseBlock(view).get()
        #expect(messages[0]["createSurface"]?["catalogId"]?.stringValue == A2UI.basicCatalogID)
        // Other code blocks and the tap block stay text; a block still streaming is pending.
        let code = "Run:\n```sh\nls\n```"
        #expect(A2UI.segments(code) == [.text(code)])
        #expect(A2UI.viewBlocks("x\n\n```a2ui-action\n{}\n```").isEmpty)
        #expect(A2UI.segments("Look:\n```a2ui\n{\"messages\":[") == [.text("Look:"), .pendingView])
        // Broken blocks explain themselves.
        if case .failure(let e) = A2UI.parseBlock("{not json") { #expect(e.message.contains("JSON")) } else { Issue.record("parsed") }
        if case .failure(let e) = A2UI.parseBlock(#"{"messages":[]}"#) { #expect(e.message.contains("No A2UI")) } else { Issue.record("parsed") }
        #expect(A2UI.sessionGuide.contains("```a2ui") && A2UI.sessionGuide.contains("createSurface"))
        #expect(!A2UI.guide.contains("info string"))
    }

    /// A2UI over MCP: embedded `application/a2ui+json` resources and the `_meta.ui` layout pointer.
    @Test func recognizesA2UIFromMCP() {
        let data: JSONValue = ["version": "1.0", "updateDataModel": ["surfaceId": "c", "path": "/t", "value": "x"]]
        let item: JSONValue = ["type": "resource", "resource": ["uri": "a2ui://c/data", "mimeType": .string(A2UI.mimeType), "text": .string(data.jsonString())]]
        #expect(A2UI.mcpMessages(item) == [data])
        #expect(A2UI.mcpMessages(["type": "resource", "resource": ["uri": "file:///x", "mimeType": "text/plain", "text": "hi"]]) == nil)
        #expect(A2UI.mcpMessages(["type": "text", "text": "hi"]) == nil)
        #expect(A2UI.mcpTemplateURI(["ui": ["resourceUri": "a2ui://card", "mimeType": .string(A2UI.mimeType)]]) == "a2ui://card")
        #expect(A2UI.mcpTemplateURI(["ui": ["resourceUri": "ui://widget", "mimeType": "text/html;profile=mcp-app"]]) == nil)
        #expect(A2UI.mcpTemplateURI(nil) == nil)
    }
}
