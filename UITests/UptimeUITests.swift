import XCTest

/// Uptime on a disposable test server with cron: turn checks on, add a check that is up and one that is down,
/// see the down one offer an agent investigation, then delete both.
final class UptimeUITests: XCTestCase {
    func testAddUpAndDownChecks() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else {
            throw XCTSkip("No uptime test server")
        }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_UPTIME_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_UPTIME_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()

        let row = app.buttons["dashboard.uptime"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 6 { app.swipeUp(); tries += 1 }
        row.tap()

        let install = app.buttons["uptime.install"]
        if install.waitForExistence(timeout: 30) {
            shot(app, "off")
            install.tap()
        }
        let add = app.buttons["uptime.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 60))

        addCheck(app, url: "https://example.com", name: "Example")
        XCTAssertTrue(app.staticTexts["Example"].waitForExistence(timeout: 60))
        addCheck(app, url: "http://127.0.0.1:9/health", name: "Local API")
        XCTAssertTrue(app.staticTexts["Local API"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["Investigate with an agent"].waitForExistence(timeout: 30))
        sleep(1)
        shot(app, "checks")

        for name in ["Local API", "Example"] {
            let text = app.staticTexts[name]
            text.swipeLeft()
            app.buttons["Delete"].firstMatch.tap()
            let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: text)
            wait(for: [gone], timeout: 30)
        }
    }

    private func addCheck(_ app: XCUIApplication, url: String, name: String) {
        app.buttons["uptime.add"].tap()
        let field = app.textFields["check.url"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(url)
        let nameField = app.textFields["Name (optional)"]
        nameField.tap()
        nameField.typeText(name)
        app.buttons["check.save"].tap()
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
