import XCTest

/// The home-screen status widget's faces (DECKHAND_WIDGET_PREVIEW shows them in the app, since the simulator's
/// home screen can't be scripted) and the values the app saves for it after a real fetch.
final class StatusWidgetUITests: XCTestCase {
    func testDemoFaces() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_WIDGET_PREVIEW"] = "demo"
        if let look = ProcessInfo.processInfo.environment["DECKHAND_APPEARANCE"] { app.launchEnvironment["DECKHAND_APPEARANCE"] = look }
        app.launch()
        let small = app.otherElements["widget.small"]
        XCTAssertTrue(small.waitForExistence(timeout: 15))
        // The fullest disk comes first, in its warning color.
        XCTAssertTrue(small.staticTexts["web-1"].exists)
        XCTAssertTrue(small.staticTexts["96 %"].exists)
        XCTAssertTrue(app.otherElements["widget.medium"].staticTexts["staging"].exists)
        XCTAssertTrue(app.staticTexts["No server status yet"].exists)
        shot(app, "faces")
    }

    /// Needs TEST_RUNNER_DECKHAND_UPTIME_HOST/_PORT/_USER/_PASSWORD.
    func testValuesFromTheLastFetch() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else { throw XCTSkip("No test server") }
        let app = XCUIApplication()
        app.launchEnvironment = ["DECKHAND_RESET": "1", "DECKHAND_SEED_HOST": host, "DECKHAND_SEED_PORT": env["DECKHAND_UPTIME_PORT"] ?? "22",
                                 "DECKHAND_SEED_USER": env["DECKHAND_UPTIME_USER"] ?? "me", "DECKHAND_SEED_PASSWORD": password,
                                 "DECKHAND_SEED_NAME": "sandbox", "DECKHAND_SEED_TRUST": "1", "DECKHAND_SEED_RUN": "server|"]
        app.launch()
        XCTAssertTrue(app.staticTexts["CPU"].waitForExistence(timeout: 40))
        app.terminate()

        let preview = XCUIApplication()
        preview.launchEnvironment = ["DECKHAND_WIDGET_PREVIEW": "live"]
        preview.launch()
        let small = preview.otherElements["widget.small"]
        XCTAssertTrue(small.waitForExistence(timeout: 15))
        XCTAssertTrue(small.staticTexts["sandbox"].exists)
        let percents = small.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' %'"))
        // CPU and RAM always; disk too, or "–" on a container without a real filesystem.
        XCTAssertTrue(percents.count == 3 || (percents.count == 2 && small.staticTexts["–"].exists), "\(percents.count)")
        shot(preview, "live")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
