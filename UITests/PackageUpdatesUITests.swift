import XCTest

/// Updates screen on a Debian/Ubuntu server (DECKHAND_WEB_HOST/PORT/USER/KEY): summary, package list, the install
/// sheet (cancelled — installing is covered by the live test in a throwaway container).
final class PackageUpdatesUITests: XCTestCase {
    func testListAndInstallSheet() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_WEB_HOST"], let key = env["DECKHAND_WEB_KEY"] else { throw XCTSkip("No server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_WEB_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_WEB_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_KEY"] = key
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "web-1"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()

        let row = app.buttons["dashboard.updates"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        for _ in 0..<10 where !app.navigationBars["Updates"].exists {
            if row.exists && row.isHittable { row.tap() }
            _ = app.navigationBars["Updates"].waitForExistence(timeout: 3)
        }
        let summary = app.descendants(matching: .any)["updates.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 90))
        shot(app, "updates")

        let all = app.buttons["updates.all"]
        if all.exists {
            all.tap()
            XCTAssertTrue(app.navigationBars["Install All Updates"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["rootTask.confirm"].exists)
            shot(app, "install-sheet")
            app.buttons["Cancel"].tap()
            XCTAssertTrue(summary.waitForExistence(timeout: 30))
        }
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
}
