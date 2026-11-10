import XCTest

/// Process list on the demo server: CPU/memory sorting, search, the end dialog (cancelled — ending is covered by
/// the live test). TEST_RUNNER_DECKHAND_DEMO_*.
final class ProcessesUITests: XCTestCase {
    func testListSortSearchAndEndDialog() throws {
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

        let row = app.buttons["dashboard.processes"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        let header = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'processes ·'")).firstMatch
        for _ in 0..<10 where !app.navigationBars["Processes"].exists {
            if row.exists && row.isHittable { row.tap() }
            _ = app.navigationBars["Processes"].waitForExistence(timeout: 3)
        }
        XCTAssertTrue(header.waitForExistence(timeout: 30))
        let anyProcess = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'process.'")).firstMatch
        XCTAssertTrue(anyProcess.waitForExistence(timeout: 10))
        shot(app, "cpu")

        app.buttons["Memory"].tap()
        sleep(1)
        shot(app, "memory")

        let search = app.searchFields.firstMatch
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("sshd")
        let sshd = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'sshd'")).firstMatch
        XCTAssertTrue(sshd.waitForExistence(timeout: 10))
        shot(app, "search")

        let first = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'process.'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.press(forDuration: 1.0)
        let end = app.buttons["End Process…"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        end.tap()
        let force = app.buttons["Force Quit"]
        XCTAssertTrue(force.waitForExistence(timeout: 5))
        shot(app, "end-dialog")
        // Dismiss without ending anything.
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap() }
        XCTAssertTrue(first.waitForExistence(timeout: 5))
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
}
