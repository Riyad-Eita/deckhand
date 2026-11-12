import XCTest

/// Bug #79: the task's title stays in the navigation bar after a run ends (and after leaving and reopening the task).
/// The run uses a deliberately invalid key, so it ends quickly with an error. Needs TEST_RUNNER_DECKHAND_UPTIME_*.
final class ChatTitleUITests: XCTestCase {
    func testTitleStaysAfterARun() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else { throw XCTSkip("No test server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_UPTIME_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_UPTIME_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_APIKEY"] = "invalid-test-key"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "ownKey|Check the disk space"
        app.launch()

        let title = app.navigationBars.staticTexts["Check the disk space"]
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Stop"].waitForNonExistence(timeout: 60), "run didn't end")
        sleep(1)
        XCTAssertTrue(title.exists, "title gone after the run")
        // Back to the task list and in again.
        app.navigationBars.buttons.firstMatch.tap()
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Check the disk space'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10), "title gone after reopening")
        for style in ["light", "dark"] {
            let s = XCTAttachment(screenshot: app.screenshot()); s.name = style; s.lifetime = .keepAlways; add(s)
            if style == "light" { XCUIDevice.shared.appearance = .dark; sleep(1) }
        }
        XCUIDevice.shared.appearance = .light
    }
}
