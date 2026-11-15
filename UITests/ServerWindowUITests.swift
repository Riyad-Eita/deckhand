import XCTest

/// iPad and Mac: a server opens in a window of its own from its context menu.
/// Run on an iPad simulator. Needs TEST_RUNNER_DECKHAND_UPTIME_HOST/_PORT/_USER/_PASSWORD.
final class ServerWindowUITests: XCTestCase {
    func testOpenServerInNewWindow() throws {
        let env = ProcessInfo.processInfo.environment
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else { throw XCTSkip("No test server") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment = ["DECKHAND_RESET": "1", "DECKHAND_SEED_SKIPAUTH": "1", "DECKHAND_SEED_HOST": host,
                                 "DECKHAND_SEED_PORT": env["DECKHAND_UPTIME_PORT"] ?? "22", "DECKHAND_SEED_USER": env["DECKHAND_UPTIME_USER"] ?? "me",
                                 "DECKHAND_SEED_PASSWORD": password, "DECKHAND_SEED_NAME": "web-1", "DECKHAND_SEED_TRUST": "1",
                                 "DECKHAND_DEMO_ADDRESS": "web-1=deploy@web-1.example.com"]
        app.launch()

        let row = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'web-1,'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.press(forDuration: 1.2)
        let open = app.buttons["Open in New Window"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit"].exists)
        open.tap()

        // The new window shows just the server, without the sidebar.
        XCTAssertTrue(app.buttons["Server"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["web-1"].waitForExistence(timeout: 5) || app.staticTexts["web-1"].exists)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "window"; a.lifetime = .keepAlways; add(a)
    }
}
