import XCTest

/// Server X-ray on a disposable test server with nginx and a site that points to a port where nothing runs.
final class ServerXrayUITests: XCTestCase {
    func testScanShowsMapAndRisks() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"],
              let site = env["DECKHAND_XRAY_SITE"] else { throw XCTSkip("No test server") }
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
        let row = app.buttons["dashboard.xray"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 8 { app.swipeUp(); tries += 1 }
        row.tap()
        let scan = app.buttons["xray.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 20))
        scan.tap()
        XCTAssertTrue(app.staticTexts["No backups found"].waitForExistence(timeout: 120))
        XCTAssertTrue(app.staticTexts["\(site) points to nothing"].exists)
        sleep(1)
        shot(app, "risks")
        var t = 0
        while !app.staticTexts[site].isHittable && t < 6 { app.swipeUp(); t += 1 }
        XCTAssertTrue(app.staticTexts[site].exists)
        shot(app, "flow")
        let notes = app.buttons["xray.notes"]
        t = 0
        while !notes.isHittable && t < 10 { app.swipeUp(); t += 1 }
        notes.tap()
        XCTAssertTrue(app.buttons["Saved to server notes"].waitForExistence(timeout: 30))
        shot(app, "saved")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
