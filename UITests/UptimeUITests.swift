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

        // The incident: evidence from the server, then the agents to hand it to.
        app.buttons["Investigate with an agent"].tap()
        XCTAssertTrue(app.buttons["Request"].waitForExistence(timeout: 90))
        XCTAssertTrue(app.buttons["incident.codex"].exists)
        app.buttons["Request"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'HTTP 000'")).firstMatch.waitForExistence(timeout: 5))
        shot(app, "incident")
        app.navigationBars.buttons.firstMatch.tap()

        for name in ["Local API", "Example"] {
            let text = app.staticTexts[name]
            text.swipeLeft()
            app.buttons["Delete"].firstMatch.tap()
            let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: text)
            wait(for: [gone], timeout: 30)
        }
    }

    /// A check that is down, an automatic fix that starts the service, "Check now": the server heals it.
    func testAutomaticFix() throws {
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
        if install.waitForExistence(timeout: 20) { install.tap() }
        XCTAssertTrue(app.buttons["uptime.add"].waitForExistence(timeout: 60))
        addCheck(app, url: "http://127.0.0.1:8099/", name: "Local API")
        let name = app.staticTexts["Local API"]
        XCTAssertTrue(name.waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["Investigate with an agent"].waitForExistence(timeout: 30))

        name.swipeLeft()
        app.buttons["Auto-fix"].firstMatch.tap()
        let editor = app.textViews["remedy.commands"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("setsid python3 -m http.server 8099 --bind 127.0.0.1 >/dev/null 2>&1 < /dev/null &")
        app.buttons["remedy.save"].tap()
        XCTAssertTrue(app.staticTexts["Fixes itself when it fails"].waitForExistence(timeout: 30))

        app.buttons["Check now"].tap()
        XCTAssertTrue(app.staticTexts["Fixed itself 1× today"].waitForExistence(timeout: 90))
        sleep(1)
        shot(app, "healed")
        app.staticTexts["Local API"].swipeLeft()
        app.buttons["Auto-fix"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Fixed"].waitForExistence(timeout: 10))
        shot(app, "remedy")
        app.buttons["Stop fixing automatically"].tap()
        XCTAssertTrue(app.staticTexts["Local API"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["Fixes itself when it fails"].waitForExistence(timeout: 5))
        app.staticTexts["Local API"].swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts["Local API"])
        wait(for: [gone], timeout: 30)
    }

    func testIncidentLeavesACheck() throws {
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
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "checkoffer|"
        app.launch()
        let add = app.buttons["checkoffer.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        shot(app, "offer")
        add.tap()
        XCTAssertTrue(app.buttons["Added to Uptime"].waitForExistence(timeout: 60))
    }

    func testSuggestedFixBar() throws {
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
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "fix|"
        app.launch()
        XCTAssertTrue(app.buttons["fix.apply"].waitForExistence(timeout: 30))
        shot(app, "fix")
        app.buttons["Not now"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["fix.apply"])
        wait(for: [gone], timeout: 5)
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
