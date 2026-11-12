import XCTest

/// The action log of a seeded task (a `cat .env` call): entry with its output, totals, and the export sheet.
/// Needs a server to open (TEST_RUNNER_DECKHAND_UPTIME_*).
final class ActionLogUITests: XCTestCase {
    func testLogAndExport() throws {
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
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "secrets|"
        app.launch()
        let log = app.buttons["chat.log"]
        XCTAssertTrue(log.waitForExistence(timeout: 40))
        log.tap()
        let entry = app.buttons["log.entry.command"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["cat .env"].exists)
        XCTAssertTrue(app.staticTexts["Commands"].exists)
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let expanded = app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS 'DATABASE_URL'")).firstMatch
        XCTAssertTrue(expanded.waitForExistence(timeout: 5))
        // Secrets stay masked in the log, like in the chat.
        XCTAssertFalse(app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS 'ghp_'")).firstMatch.exists)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "log"; s.lifetime = .keepAlways; add(s)
        app.buttons["log.export"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10) || app.buttons["Copy"].waitForExistence(timeout: 5))
    }
}
