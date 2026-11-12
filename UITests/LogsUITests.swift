import XCTest

/// Logs: find the demo app's log, see its error, filter, and hand it to an agent.
final class LogsUITests: XCTestCase {
    func testOpenLogFilterAndExplain() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_DEMO_HOST"], let password = env["DECKHAND_DEMO_PASSWORD"] else { throw XCTSkip("No demo server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_DEMO_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_DEMO_USER"] ?? "demo"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()

        let logs = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Logs'")).firstMatch
        XCTAssertTrue(logs.waitForExistence(timeout: 30))
        logs.tap()
        let appLog = app.buttons.containing(NSPredicate(format: "label CONTAINS 'app.log'")).firstMatch
        XCTAssertTrue(appLog.waitForExistence(timeout: 30))
        appLog.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'city not found'")).firstMatch.waitForExistence(timeout: 20))
        app.buttons["Errors"].tap()
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'started on'")).firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        app.buttons["logs.explain"].tap()
        // A quick explanation first (on-device model or your key); "Fix it" hands it to an agent.
        let fix = app.buttons["explain.fix"]
        if fix.waitForExistence(timeout: 30) { fix.tap() } else { throw XCTSkip("No on-device model or key for the explanation") }
        let codex = app.buttons["Codex on the server"]
        XCTAssertTrue(codex.waitForExistence(timeout: 5))
        codex.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Explain in plain words'")).firstMatch.waitForExistence(timeout: 15))
        // (The task gets the logs prompt: what the lines mean and what to do.)
        if app.buttons["Stop"].firstMatch.exists { app.buttons["Stop"].firstMatch.tap() }
    }
}
