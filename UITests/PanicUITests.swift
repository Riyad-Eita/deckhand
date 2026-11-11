import XCTest

/// Panic button on a disposable test server (logged in with a key, since the lockdown turns passwords off):
/// lock down with nginx stopped, see the summary, then give the all clear.
final class PanicUITests: XCTestCase {
    func testLockDownAndAllClear() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_PANIC_HOST"], let key = env["DECKHAND_PANIC_KEY"], let sudo = env["DECKHAND_PANIC_SUDO"] else {
            throw XCTSkip("No test server")
        }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_PANIC_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_PANIC_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_KEY"] = key.replacingOccurrences(of: "\\n", with: "\n")
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_SKIPAUTH"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()
        let row = app.buttons["dashboard.panic"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 12 { app.swipeUp(); tries += 1 }
        row.tap()
        XCTAssertTrue(app.buttons["panic.lock"].waitForExistence(timeout: 30))
        // Servers without D-Bus (containers) list no services; on real servers nginx can be stopped too.
        let nginx = app.switches["nginx"]
        if nginx.waitForExistence(timeout: 5) { nginx.switches.firstMatch.tap() }
        shot(app, "plan")
        let lock = app.buttons["panic.lock"]
        var t = 0
        while !lock.isHittable && t < 6 { app.swipeUp(); t += 1 }
        lock.tap()
        let pw = app.secureTextFields.firstMatch
        XCTAssertTrue(pw.waitForExistence(timeout: 20))
        pw.typeText(sudo)
        app.alerts.buttons["Continue"].tap()
        let go = app.buttons["Lock down"]
        XCTAssertTrue(go.waitForExistence(timeout: 30))
        go.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 240))
        shot(app, "applied")
        done.tap()
        XCTAssertTrue(app.staticTexts["This server is locked down"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Evidence files"].waitForExistence(timeout: 30))
        sleep(1)
        shot(app, "locked")
        let clear = app.buttons["panic.allclear"]
        t = 0
        while !clear.isHittable && t < 6 { app.swipeUp(); t += 1 }
        clear.tap()
        XCTAssertTrue(app.buttons["panic.lock"].waitForExistence(timeout: 120))
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
