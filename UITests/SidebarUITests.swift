import XCTest

/// iPad and Mac: the home list is a sidebar; servers and tools open next to it.
/// Run on an iPad simulator. Needs TEST_RUNNER_DECKHAND_UPTIME_HOST/_PORT/_USER/_PASSWORD.
final class SidebarUITests: XCTestCase {
    func testServersAndToolsOpenNextToTheSidebar() throws {
        let env = ProcessInfo.processInfo.environment
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else { throw XCTSkip("No test server") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment = ["DECKHAND_RESET": "1", "DECKHAND_SEED_SKIPAUTH": "1", "DECKHAND_SEED_HOST": host,
                                 "DECKHAND_SEED_PORT": env["DECKHAND_UPTIME_PORT"] ?? "22", "DECKHAND_SEED_USER": env["DECKHAND_UPTIME_USER"] ?? "me",
                                 "DECKHAND_SEED_PASSWORD": password, "DECKHAND_SEED_NAME": "web-1", "DECKHAND_SEED_TRUST": "1",
                                 "DECKHAND_DEMO_ADDRESS": "web-1=deploy@web-1.example.com",
                                 "DECKHAND_SEED_EXTRA": "db|db.example.com|deploy;staging|staging.example.com|deploy"]
        if let look = env["DECKHAND_APPEARANCE"] { app.launchEnvironment["DECKHAND_APPEARANCE"] = look }
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["sidebar.placeholder"].waitForExistence(timeout: 20))
        let row = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'web-1,'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        shot(app, "empty")
        row.tap()
        XCTAssertTrue(app.buttons["Server"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(row.isHittable, "the sidebar stays visible")
        app.buttons["Server"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["CPU"].waitForExistence(timeout: 30))
        shot(app, "server")

        let appStore = app.buttons["home.appstore"]
        for _ in 0..<5 where !appStore.isHittable { row.swipeUp() }
        appStore.tap()
        XCTAssertTrue(app.navigationBars["App Store Connect"].waitForExistence(timeout: 10) || app.staticTexts["App Store Connect"].waitForExistence(timeout: 5))
        shot(app, "tool")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
