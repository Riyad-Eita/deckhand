import XCTest

/// Security check-up on a disposable systemd server (DECKHAND_PORT_*): score, explanations, a plain fix
/// (automatic updates) and a guarded one (SSH limits, with a fresh login before it's kept), and the score going up.
final class SecurityAuditUITests: XCTestCase {
    func testAuditAndFix() throws {
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

        let row = app.buttons["dashboard.audit"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 4 { app.swipeUp(); tries += 1 }
        row.tap()
        let pw = app.secureTextFields.firstMatch
        XCTAssertTrue(pw.waitForExistence(timeout: 15))
        pw.typeText(password)
        app.alerts.buttons["Continue"].tap()
        XCTAssertTrue(app.buttons["check.ssh.password"].waitForExistence(timeout: 60))
        app.buttons["check.ssh.password"].tap()
        sleep(1)
        shot(app, "audit")

        for id in ["autoupdates", "ssh.extras"] {
            let check = app.buttons["check.\(id)"]
            tries = 0
            while !check.isHittable && tries < 5 { app.swipeUp(); tries += 1 }
            check.tap()
            let fix = app.buttons["fix.\(id)"]
            XCTAssertTrue(fix.waitForExistence(timeout: 5))
            fix.tap()
            app.buttons["rootTask.confirm"].tap()
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 240))
            shot(app, "fixed-\(id)")
            done.tap()
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Up from'")).firstMatch.waitForExistence(timeout: 60))
            app.swipeDown(); app.swipeDown()
        }
        shot(app, "after")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
}
