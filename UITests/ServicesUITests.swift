import XCTest

/// Services list → failed service → restart → sudo needs a password → command opens in the terminal.
/// Uses TEST_RUNNER_DECKHAND_DASH_* (a server where the user has no passwordless sudo). Never types a password.
final class ServicesUITests: XCTestCase {
    func testFailedServiceRestartGoesToTerminal() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_DASH_HOST"], let key = env["DECKHAND_DASH_KEY"] else { throw XCTSkip("No server configured") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_DASH_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_DASH_USER"] ?? "root"
        app.launchEnvironment["DECKHAND_SEED_KEY"] = key
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "web-1"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()

        let services = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Services'")).firstMatch
        XCTAssertTrue(services.waitForExistence(timeout: 30))
        services.tap()
        let failedRow = app.buttons.containing(NSPredicate(format: "label CONTAINS 'failed'")).firstMatch
        XCTAssertTrue(failedRow.waitForExistence(timeout: 20), "expected at least one failed service")
        failedRow.tap()
        XCTAssertTrue(app.staticTexts["Investigate with an agent"].waitForExistence(timeout: 10))
        let restart = app.buttons["Restart"]
        XCTAssertTrue(restart.waitForExistence(timeout: 10))
        restart.tap()
        let runInTerminal = app.alerts.buttons["Run in Terminal"]
        XCTAssertTrue(runInTerminal.waitForExistence(timeout: 30))
        runInTerminal.tap()
        XCTAssertTrue(app.navigationBars["Terminal"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 6)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
    }
}
