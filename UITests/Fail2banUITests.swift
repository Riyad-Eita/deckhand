import XCTest

/// Blocked logins on a disposable server (DECKHAND_PORT_*). Run `test1SetUp` on a server without fail2ban,
/// ban an address on the server, then run `test2BannedList`.
final class Fail2banUITests: XCTestCase {
    func launch() throws -> (XCUIApplication, String) {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_PORT_HOST"], let password = env["DECKHAND_PORT_PASSWORD"] else { throw XCTSkip("No test server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_PORT_OLD"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_PORT_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "web-1"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()
        let row = app.buttons["dashboard.fail2ban"]
        XCTAssertTrue(app.buttons["dashboard.audit"].waitForExistence(timeout: 40) || row.exists)
        var tries = 0
        while !(row.exists && row.isHittable) && tries < 8 { app.swipeUp(); tries += 1 }
        row.tap()
        let pw = app.secureTextFields.firstMatch
        XCTAssertTrue(pw.waitForExistence(timeout: 15))
        pw.typeText(password)
        app.alerts.buttons["Continue"].tap()
        return (app, password)
    }

    func test1SetUp() throws {
        let (app, _) = try launch()
        let setup = app.buttons["fail2ban.setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 30))
        setup.tap()
        app.buttons["rootTask.confirm"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 300))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Failed SSH logins"].waitForExistence(timeout: 30))
    }

    func test2BannedList() throws {
        let (app, _) = try launch()
        let ip = app.staticTexts["203.0.113.9"]
        XCTAssertTrue(ip.waitForExistence(timeout: 30))
        sleep(3)
        shot(app, "banned")
        app.buttons["Unban"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Nobody is banned right now."].waitForExistence(timeout: 30))
        let allow = app.buttons["fail2ban.allowMe"]
        var tries = 0
        while !allow.isHittable && tries < 4 { app.swipeUp(); tries += 1 }
        allow.tap()
        app.buttons["rootTask.confirm"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 60))
        app.buttons["Done"].tap()
        // The view reloads after the sheet closes; then my address is on the list and the button is gone.
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["fail2ban.allowMe"])
        wait(for: [gone], timeout: 30)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
}
