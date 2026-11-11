import XCTest

/// Agent tab on a server where Claude Code isn't signed in (DECKHAND_WEB_*): the tile says "Sign in", opens the
/// three-step sign-in, and "Sign in with Claude" opens Claude's page in Apple's sign-in sheet.
final class AgentSignInUITests: XCTestCase {
    func testClaudeTileLeadsToSignIn() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_WEB_HOST"], let key = env["DECKHAND_WEB_KEY"] else { throw XCTSkip("No server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_WEB_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_WEB_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_KEY"] = key
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "web-1"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launch()

        app.buttons.containing(NSPredicate(format: "label CONTAINS 'web-1'")).firstMatch.tap()
        let tile = app.buttons["engine.claudeCode"]
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        let signIn = expectation(for: NSPredicate(format: "label CONTAINS 'Sign in'"), evaluatedWith: tile)
        wait(for: [signIn], timeout: 40)
        shot(app, "tiles")
        tile.tap()
        let open = app.buttons["login.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 60))
        shot(app, "steps")
        open.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Continue"].waitForExistence(timeout: 10) { springboard.buttons["Continue"].tap() }
        sleep(8)
        let page = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); page.name = "page"; page.lifetime = .keepAlways; add(page)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
}
