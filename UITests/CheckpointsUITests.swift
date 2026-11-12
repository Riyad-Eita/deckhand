import XCTest

/// Files an agent changed during a task, with diffs and undo. The seed prepares ~/dh-checkpoint-test on the test
/// server, snapshots it as the task's start and changes it (edit, add, delete). Needs TEST_RUNNER_DECKHAND_UPTIME_*.
final class CheckpointsUITests: XCTestCase {
    func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }

    func testSeeAndUndoChanges() throws {
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
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "checkpoint|"
        app.launch()

        let link = app.buttons["chat.changes"]
        XCTAssertTrue(link.waitForExistence(timeout: 60))
        link.tap()
        XCTAssertTrue(app.descendants(matching: .any)["change.a.txt"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["change.new.txt"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["change.old.txt"].exists)
        shot(app, "changes")

        // The diff of one file.
        app.descendants(matching: .any)["change.a.txt"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'TWO'")).firstMatch.waitForExistence(timeout: 10))
        shot(app, "diff")
        app.navigationBars.buttons.firstMatch.tap()

        // Undo one file, then the rest.
        let added = app.descendants(matching: .any)["change.new.txt"].firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 10))
        added.swipeLeft()
        app.buttons["Undo"].firstMatch.tap()
        XCTAssertTrue(added.waitForNonExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["change.a.txt"].exists)
        app.buttons["changes.undoAll"].tap()
        app.buttons["Undo all"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Nothing changed'")).firstMatch.waitForExistence(timeout: 30))
        shot(app, "undone")
    }
}
