import XCTest

/// "Go to" (TEST_RUNNER_DECKHAND_UPTIME_*): finds the server by typing, and runs "status cron on sandbox" as an action.
final class CommandPaletteUITests: XCTestCase {
    func testSearchAndAction() throws {
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
        app.launchEnvironment["DECKHAND_SEED_EXTRA"] = "web-1|example.invalid|me"
        app.launch()
        let search = app.buttons["home.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("sand")
        XCTAssertTrue(app.buttons["palette.server.sandbox"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["palette.server.web-1"].exists)
        field.typeText("\u{8}\u{8}\u{8}\u{8}status cron on sandbox")
        let action = app.buttons["palette.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertTrue(action.label.contains("Status cron on sandbox"), action.label)
        action.tap()
        XCTAssertTrue(app.staticTexts["palette.output"].waitForExistence(timeout: 30) || app.descendants(matching: .any)["palette.output"].exists)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "palette"; s.lifetime = .keepAlways; add(s)
        app.buttons["Close"].tap()
        search.tap()
        let again = app.searchFields.firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        again.tap(); again.typeText("sandbox")
        app.buttons["palette.server.sandbox"].tap()
        XCTAssertTrue(app.buttons["dashboard.files"].waitForExistence(timeout: 30) || app.staticTexts["sandbox"].waitForExistence(timeout: 5))
    }
}
