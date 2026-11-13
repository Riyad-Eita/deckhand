import XCTest

/// Errors say what kind of problem it is and what to do: an address that doesn't exist (network) and a wrong password
/// (sign-in) on the dashboard. The wrong-password case needs the test server (TEST_RUNNER_DECKHAND_UPTIME_*).
final class PlainErrorsUITests: XCTestCase {
    private func open(_ app: XCUIApplication) {
        let server = app.staticTexts["broken"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.tap()
        app.buttons["Server"].tap()
    }

    func testUnknownAddress() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = "no-such-host.invalid"
        app.launchEnvironment["DECKHAND_SEED_USER"] = "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = "unused"
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "broken"
        app.launch()
        open(app)
        let hint = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Check the spelling of the address'")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 40))
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "network"; s.lifetime = .keepAlways; add(s)
    }

    func testWrongPassword() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_UPTIME_HOST"] else { throw XCTSkip("No test server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_UPTIME_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_UPTIME_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = "definitely-wrong"
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "broken"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launch()
        open(app)
        let hint = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Check the user name and password'")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 40))
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "signin"; s.lifetime = .keepAlways; add(s)
    }
}
