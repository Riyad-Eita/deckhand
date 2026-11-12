import XCTest

/// Copy to another server from the file browser (TEST_RUNNER_DECKHAND_UPTIME_*): the sheet lists the other servers,
/// and a server Deckhand never connected to (no pinned host key) can't be a target yet. The copy itself is covered by
/// LiveServerCopyTests.
final class ServerCopyUITests: XCTestCase {
    func testCopySheet() throws {
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
        app.launchEnvironment["DECKHAND_SEED_EXTRA"] = "backup-box|backup.example.com|me"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()
        let files = app.buttons["dashboard.files"]
        XCTAssertTrue(files.waitForExistence(timeout: 40))
        var t = 0
        while !files.isHittable && t < 10 { app.swipeUp(); t += 1 }
        files.tap()
        let entry = app.buttons.containing(NSPredicate(format: "label CONTAINS 'app'")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30))
        entry.press(forDuration: 1.2)
        let copy = app.buttons["Copy to Another Server…"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        let picker = app.buttons["copy.target"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        app.buttons["backup-box"].tap()
        XCTAssertTrue(app.staticTexts["Open backup-box once first, so Deckhand knows its host key."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["copy.start"].isEnabled)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "copy"; s.lifetime = .keepAlways; add(s)
    }
}
