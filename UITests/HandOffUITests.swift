import XCTest

/// "Continue on a computer" in a Codex task: the sheet shows the SSH command that resumes the session in its folder.
/// Needs a server to open (TEST_RUNNER_DECKHAND_DEMO_*).
final class HandOffUITests: XCTestCase {
    func testContinueOnAComputer() throws {
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
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "markdown|"
        app.launch()

        let menu = app.buttons["chat.modelMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        menu.tap()
        let handoff = app.buttons["chat.handoff"]
        XCTAssertTrue(handoff.waitForExistence(timeout: 5))
        handoff.tap()
        let command = app.staticTexts["handoff.command"]
        XCTAssertTrue(command.waitForExistence(timeout: 10))
        XCTAssertTrue(command.label.hasPrefix("ssh -t "), command.label)
        XCTAssertTrue(command.label.contains("codex resume"), command.label)
        XCTAssertTrue(command.label.contains("019a7c2e-demo-session"), command.label)
        app.buttons["handoff.copy"].tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 3))
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "handoff"; s.lifetime = .keepAlways; add(s)
    }
}
