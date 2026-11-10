import XCTest

/// File browser on the demo server (TEST_RUNNER_DECKHAND_DEMO_*): navigate, hidden files, new folder, rename, delete,
/// and hand a file to the agent. Leaves nothing behind (the test folder is deleted again).
final class FilesUITests: XCTestCase {
    func testBrowseChangeAndAskTheAgent() throws {
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

        let row = app.buttons["dashboard.files"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        // The dashboard refreshes every few seconds; tap once the row is settled.
        for _ in 0..<10 where !app.buttons["file.projects"].exists {
            if row.exists && row.isHittable { row.tap() }
            _ = app.buttons["file.projects"].waitForExistence(timeout: 3)
        }

        // Home folder: hidden files only after switching them on.
        let projects = app.buttons["file.projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["file..ssh"].exists)
        app.buttons["files.menu"].tap()
        app.buttons["Show Hidden Files"].tap()
        XCTAssertTrue(app.buttons["file..ssh"].waitForExistence(timeout: 5))
        shot(app, "home-hidden")
        app.buttons["files.menu"].tap()
        app.buttons["Show Hidden Files"].tap()

        // New folder, rename, delete.
        app.buttons["files.menu"].tap()
        app.buttons["New Folder"].tap()
        let alert = app.alerts["New Folder"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.typeText("deckhand-ui-test")
        alert.buttons["Create"].tap()
        let created = app.buttons["file.deckhand-ui-test"]
        XCTAssertTrue(created.waitForExistence(timeout: 20))

        created.swipeLeft()
        app.buttons["Rename"].tap()
        let rename = app.alerts["Rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        let field = rename.textFields.firstMatch
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "deckhand-renamed")
        rename.buttons["Rename"].tap()
        let renamed = app.buttons["file.deckhand-renamed"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 20))
        XCTAssertFalse(created.exists)

        renamed.swipeLeft()
        app.buttons["Delete"].tap()
        let confirm = app.sheets.buttons["Delete"].exists ? app.sheets.buttons["Delete"] : app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(waitForGone(renamed, timeout: 20))

        // Into a project and hand a file to the agent.
        projects.tap()
        let repo = app.buttons["file.weather-api"]
        XCTAssertTrue(repo.waitForExistence(timeout: 20))
        repo.tap()
        let readme = app.buttons["file.README.md"]
        XCTAssertTrue(readme.waitForExistence(timeout: 20))
        shot(app, "project")
        readme.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'weather'")).firstMatch.waitForExistence(timeout: 20))
        shot(app, "viewer")
        app.navigationBars.buttons.firstMatch.tap()

        readme.press(forDuration: 1.0)
        app.buttons["Ask the Agent"].tap()
        let codex = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Codex'")).firstMatch
        XCTAssertTrue(codex.waitForExistence(timeout: 5))
        shot(app, "engine-dialog")
        codex.tap()
        let composer = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        let filled = NSPredicate(format: "value CONTAINS 'README.md'")
        let wait = XCTNSPredicateExpectation(predicate: filled, object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 10), .completed)
        shot(app, "agent-draft")
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
}
