import XCTest

/// Attach a photo in a chat: it uploads into the task's folder on the demo server, and the message gets a note
/// with the path so the agent can use it. (Needs at least one photo in the simulator's library.)
final class UploadUITests: XCTestCase {
    func testAttachPhoto() throws {
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
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "codex|"
        app.launch()

        let attach = app.buttons["chat.attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: 30))
        attach.tap()
        app.buttons["Photo"].tap()
        // The system photo picker runs out of process: tap the first cell of its grid.
        XCTAssertTrue(app.buttons["Collections"].waitForExistence(timeout: 20) || app.staticTexts["Photos"].waitForExistence(timeout: 5))
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.41)).tap()
        if app.buttons["Add"].waitForExistence(timeout: 3) { app.buttons["Add"].tap() }
        let field = app.textFields.firstMatch
        let noted = expectation(for: NSPredicate(format: "value CONTAINS 'I uploaded a file to'"), evaluatedWith: field)
        wait(for: [noted], timeout: 60)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
    }
}
