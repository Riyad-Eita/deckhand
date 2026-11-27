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
}
