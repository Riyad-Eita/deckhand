import XCTest

/// Hardening profile on the disposable server (TEST_RUNNER_DECKHAND_UPTIME_*, DECKHAND_PROFILE_TEST=1): the database
/// profile with one allowed app server is previewed (the SSH step can't run while the app logs in with a password)
/// and applied — the firewall step is confirmed by a fresh login.
final class HardeningProfilesUITests: XCTestCase {
    func testDatabaseProfile() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_PROFILE_TEST"] == "1", let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else {
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
        app.launch()

        let server = app.staticTexts["sandbox"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.tap()
        app.buttons["Server"].tap()
        let row = app.buttons["dashboard.profiles"]
        XCTAssertTrue(row.waitForExistence(timeout: 40))
        var t = 0
        while !row.isHittable && t < 12 { app.swipeUp(); t += 1 }
        row.tap()

        app.buttons["profile.database"].tap()
        let clients = app.textFields["profile.clients"].exists ? app.textFields["profile.clients"] : app.textViews["profile.clients"]
        clients.tap()
        clients.typeText("10.0.0.5")
        app.buttons["profile.preview"].tap()
        let pw = app.secureTextFields.firstMatch
        if pw.waitForExistence(timeout: 20) { pw.typeText(password); app.alerts.buttons["Continue"].tap() }

        let firewall = app.descendants(matching: .any)["profile.item.sandbox.firewall"]
        XCTAssertTrue(firewall.waitForExistence(timeout: 120))
        let ssh = app.descendants(matching: .any)["profile.item.sandbox.ssh"]
        XCTAssertTrue(ssh.label.contains("password"), ssh.label)
        t = 0
        while !firewall.isHittable && t < 6 { app.swipeUp(); t += 1 }
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "preview"; s.lifetime = .keepAlways; add(s)

        let apply = app.buttons["profile.apply"]
        t = 0
        while !(apply.exists && apply.isHittable) && t < 8 { app.swipeUp(); t += 1 }
        apply.tap()
        app.buttons["Apply"].firstMatch.tap()
        let done = app.descendants(matching: .any)["profile.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 900))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'rolled back' OR label BEGINSWITH 'Undone'")).firstMatch.exists)
        let fw = app.descendants(matching: .any)["profile.item.sandbox.firewall"]
        t = 0
        while !fw.isHittable && t < 6 { app.swipeDown(); t += 1 }
        let r = XCTAttachment(screenshot: app.screenshot()); r.name = "applied"; r.lifetime = .keepAlways; add(r)
    }
}
