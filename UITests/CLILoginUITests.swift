import XCTest

/// "Log In" for Claude Code opens the real sign-in page inside the app (the login itself is not completed here).
final class CLILoginUITests: XCTestCase {
    func testClaudeLoginShowsSignInPage() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_DASH_HOST"], let key = env["DECKHAND_DASH_KEY"] else { throw XCTSkip("No server configured") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_DASH_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_DASH_USER"] ?? "root"
        app.launchEnvironment["DECKHAND_SEED_KEY"] = key
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "web-1"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "none|"
        app.launchEnvironment["DECKHAND_SEED_TOOLS"] = "1"
        app.launch()

        let logIn = app.buttons["Log In"]
        XCTAssertTrue(logIn.waitForExistence(timeout: 40))
        logIn.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 40), "sign-in page should open in the app")
        Thread.sleep(forTimeInterval: 6)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        app.buttons["Cancel"].firstMatch.tap()
    }
}
