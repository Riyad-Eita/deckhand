import XCTest

/// Certificates and domains on the disposable server (TEST_RUNNER_DECKHAND_UPTIME_*): turn on, watch github.com and
/// expired.badssl.com, see days left and "expired", turn off again.
final class ExpiryUITests: XCTestCase {
    func testWatchDomains() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else { throw XCTSkip("No test server") }
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
        let row = app.buttons["dashboard.expiry"]
        XCTAssertTrue(row.waitForExistence(timeout: 40))
        var t = 0
        while !row.isHittable && t < 10 { app.swipeUp(); t += 1 }
        row.tap()

        let install = app.buttons["expiry.install"], field = app.textFields["expiry.domain"]
        t = 0
        while !install.exists && !field.exists && t < 30 { sleep(1); t += 1 }
        if install.exists { install.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        for d in ["github.com", "expired.badssl.com"] {
            field.tap(); field.typeText(d)
            app.buttons["expiry.add"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["expiry.\(d)"].waitForExistence(timeout: 90))
        }
        let bad = app.descendants(matching: .any)["expiry.expired.badssl.com"]
        XCTAssertTrue(bad.label.contains("expired"), bad.label)
        let gh = app.descendants(matching: .any)["expiry.github.com"]
        XCTAssertTrue(gh.label.contains("days"), gh.label)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "expiry"; s.lifetime = .keepAlways; add(s)

        let off = app.buttons["Turn off"]
        t = 0
        while !off.isHittable && t < 6 { app.swipeUp(); t += 1 }
        off.tap()
        XCTAssertTrue(app.buttons["expiry.install"].waitForExistence(timeout: 30))
    }
}
