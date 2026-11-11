import XCTest

/// Change history on a disposable test server. Run `testTurnOn`, change something on the server (install a
/// package, edit a file in /etc), then run `testSeeChanges` with DECKHAND_HISTORY_PACKAGE set to that package.
final class ChangeHistoryUITests: XCTestCase {
    private func launch() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else {
            throw XCTSkip("No test server")
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
        let row = app.buttons["dashboard.history"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 6 { app.swipeUp(); tries += 1 }
        row.tap()
        return app
    }

    func testTurnOn() throws {
        let app = try launch()
        let install = app.buttons["history.install"]
        let on = app.buttons["history.since"]
        var t = 0
        while !install.exists && !on.exists && t < 60 { sleep(1); t += 1 }
        if on.exists && !install.exists { throw XCTSkip("History is already on for this server") }
        XCTAssertTrue(install.exists)
        shot(app, "off")
        install.tap()
        XCTAssertTrue(app.staticTexts["History starts here"].waitForExistence(timeout: 90))
    }

    func testSeeChanges() throws {
        guard let package = ProcessInfo.processInfo.environment["DECKHAND_HISTORY_PACKAGE"] else { throw XCTSkip("No change made") }
        let app = try launch()
        let latest = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "apt")).firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 90))
        sleep(1)
        shot(app, "timeline")
        latest.tap()
        XCTAssertTrue(app.staticTexts[package].waitForExistence(timeout: 30))
        sleep(1)
        shot(app, "changes")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["history.since"].tap()
        app.buttons["Last hour"].tap()
        XCTAssertTrue(app.staticTexts[package].waitForExistence(timeout: 30))
        shot(app, "since")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
