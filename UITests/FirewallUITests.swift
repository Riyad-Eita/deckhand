import XCTest

/// Firewall on a disposable server with ufw (DECKHAND_PORT_*): rules list, add the website preset (guarded,
/// with a fresh login), remove it again, and check from outside.
final class FirewallUITests: XCTestCase {
    func testRulesAndOutsideCheck() throws {
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

        let row = app.buttons["dashboard.firewall"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 5 { app.swipeUp(); tries += 1 }
        row.tap()
        let pw = app.secureTextFields.firstMatch
        XCTAssertTrue(pw.waitForExistence(timeout: 15))
        pw.typeText(password)
        app.alerts.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["22/tcp"].firstMatch.waitForExistence(timeout: 30))

        // Add the website preset.
        app.buttons["firewall.add"].tap()
        app.buttons["Website (80, 443)"].tap()
        app.buttons["rule.next"].tap()
        let confirm = app.buttons["rootTask.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 120))
        app.buttons["Done"].tap()
        let web = app.staticTexts["80,443/tcp"].firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 30))
        sleep(1)
        shot(app, "rules")

        // Remove it again.
        web.swipeLeft()
        app.buttons["Remove"].firstMatch.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 120))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["22/tcp"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["80,443/tcp"].exists)

        // The SSH rule can't be swiped away.
        app.staticTexts["22/tcp"].firstMatch.swipeLeft()
        sleep(1)
        XCTAssertFalse(app.buttons["Remove"].isHittable)
        app.staticTexts["22/tcp"].firstMatch.swipeRight()

        let scan = app.buttons["firewall.scan"]
        tries = 0
        while !scan.isHittable && tries < 4 { app.swipeUp(); tries += 1 }
        scan.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '2310'")).firstMatch.waitForExistence(timeout: 60))
        shot(app, "outside")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
}
