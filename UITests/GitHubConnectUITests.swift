import XCTest

/// Connect GitHub: on the demo server the app installs the GitHub CLI without root, starts GitHub's device
/// sign-in and shows the code next to GitHub's own page. (Finishing needs a person signing in to GitHub.)
final class GitHubConnectUITests: XCTestCase {
    func testDeviceSignInStarts() throws {
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
        app.launchEnvironment["DECKHAND_SEED_TOOLS"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()

        let connect = app.buttons["github.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 60))
        shot(app, "tools")
        connect.tap()
        let code = app.staticTexts["github.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 180))
        XCTAssertNotNil(code.label.range(of: #"^[A-Z0-9]{4}-[A-Z0-9]{4}$"#, options: .regularExpression))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
        sleep(3)
        shot(app, "device-page")
        app.buttons["Cancel"].tap()
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
}
