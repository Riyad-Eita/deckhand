import XCTest

/// Login alerts on a disposable server (DECKHAND_PORT_*, DECKHAND_NTFY_TOPIC): turn them on from the app;
/// the address the app connects from is trusted right away.
final class LoginAlertsUITests: XCTestCase {
    func testTurnOnAlerts() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_PORT_HOST"], let password = env["DECKHAND_PORT_PASSWORD"], let topic = env["DECKHAND_NTFY_TOPIC"] else {
            throw XCTSkip("No test server")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-notify.ntfy", topic]
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_PORT_OLD"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_PORT_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "web-1"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()

        let row = app.buttons["dashboard.loginAlerts"]
        XCTAssertTrue(app.buttons["dashboard.audit"].waitForExistence(timeout: 40) || row.exists)
        var tries = 0
        while !(row.exists && row.isHittable) && tries < 8 { app.swipeUp(); tries += 1 }
        row.tap()
        let pw = app.secureTextFields.firstMatch
        XCTAssertTrue(pw.waitForExistence(timeout: 15))
        pw.typeText(password)
        app.alerts.buttons["Continue"].tap()
        let enable = app.buttons["alerts.enable"]
        XCTAssertTrue(enable.waitForExistence(timeout: 30))
        enable.tap()
        app.buttons["rootTask.confirm"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 120))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["this iPhone"].waitForExistence(timeout: 30))
    }
}
