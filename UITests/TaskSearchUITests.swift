import XCTest

/// Tasks: search finds a word that only appears inside a task (with a snippet), a pinned task moves to the top, and
/// a task can be shared as Markdown.
final class TaskSearchUITests: XCTestCase {
    func testSearchPinShare() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = "example.com"
        app.launchEnvironment["DECKHAND_SEED_USER"] = "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = "unused"
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "web-1"
        app.launchEnvironment["DECKHAND_SEED_TASKS"] = [
            "Fix 502 errors|Why does nginx return 502?|PHP-FPM had crashed; I restarted php8.3-fpm and the site is back.",
            "Rotate logs|Logs fill the disk|Set up logrotate for /var/log/app with 7 days.",
            "Update packages|Install the security updates|12 packages updated, no restart needed.",
            "Check backups|Did last night's backup run?|Yes, restic finished at 03:12 with 2.1 GB.",
        ].joined(separator: ";")
        app.launch()

        let server = app.staticTexts["web-1"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.tap()
        let search = app.textFields["tasks.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))

        // A word only in the content.
        search.tap()
        search.typeText("restic")
        XCTAssertTrue(app.buttons["task.Check backups"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["task.Fix 502 errors"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'restic finished'")).firstMatch.exists)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "search"; s.lifetime = .keepAlways; add(s)
        app.buttons["Clear search"].tap()

        // Pin the oldest task: it moves to the top.
        let backups = app.buttons["task.Check backups"]
        XCTAssertTrue(backups.waitForExistence(timeout: 5))
        let fix = app.buttons["task.Fix 502 errors"]
        XCTAssertLessThan(fix.frame.minY, backups.frame.minY)
        backups.swipeRight()
        app.buttons["Pin"].tap()
        sleep(1)
        XCTAssertLessThan(app.buttons["task.Check backups"].frame.minY, app.buttons["task.Fix 502 errors"].frame.minY)
        let p = XCTAttachment(screenshot: app.screenshot()); p.name = "pinned"; p.lifetime = .keepAlways; add(p)

        // Share as Markdown.
        app.buttons["task.Fix 502 errors"].press(forDuration: 1.0)
        app.buttons["Share as Markdown"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10) || app.buttons["Copy"].waitForExistence(timeout: 5))
    }
}
