import XCTest

/// Server notes: write a note in the app, save it to the demo server.
final class ServerMemoryUITests: XCTestCase {
    func testWriteAndSaveNotes() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_DEMO_HOST"], let password = env["DECKHAND_DEMO_PASSWORD"] else { throw XCTSkip("No demo server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_DEMO_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_DEMO_USER"] ?? "demo"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "none|"
        app.launch()

        let notes = app.buttons["agent.memory"]
        XCTAssertTrue(notes.waitForExistence(timeout: 30))
        notes.tap()
        let editor = app.textViews["memory.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        editor.tap()
        editor.typeText("The weather API runs on port 8081.")
        app.buttons["memory.save"].tap()
        XCTAssertTrue(app.staticTexts["Saved."].waitForExistence(timeout: 20))
        let s = XCTAttachment(screenshot: app.screenshot()); s.lifetime = .keepAlways; add(s)
    }
}
