import XCTest

/// Server tab shows live stats; a warning can be handed to an agent with one tap.
/// Needs TEST_RUNNER_DECKHAND_DASH_HOST/_PORT/_USER/_KEY for a server whose disk is over 85 % full.
final class DashboardTests: XCTestCase {
    func testDashboardAndInvestigate() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_DASH_HOST"], let key = env["DECKHAND_DASH_KEY"] else {
            throw XCTSkip("No dashboard server configured")
        }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_DASH_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_DASH_USER"] ?? "root"
        app.launchEnvironment["DECKHAND_SEED_KEY"] = key
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "web-1"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()

        XCTAssertTrue(app.staticTexts["CPU"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Disks"].exists)
        let investigate = app.buttons["Investigate"].firstMatch
        XCTAssertTrue(investigate.waitForExistence(timeout: 10))
        investigate.tap()
        let codex = app.buttons["Codex on the server"]
        XCTAssertTrue(codex.waitForExistence(timeout: 5))
        codex.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Find out what causes it'")).firstMatch.waitForExistence(timeout: 20))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        app.buttons["Stop"].tapIfExists()
    }
}

private extension XCUIElement {
    func tapIfExists() { if exists { tap() } }
}
