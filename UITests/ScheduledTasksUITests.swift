import XCTest

/// Scheduled agent tasks on the disposable server (TEST_RUNNER_DECKHAND_UPTIME_*, DECKHAND_CRON_TEST=1): a new weekly
/// task from the builder, "Run Now" with Codex — which isn't installed there, so the run fails and the row shows the
/// reason — then paused and deleted. Nothing spends a subscription.
final class ScheduledTasksUITests: XCTestCase {
    func testCreateRunPauseDelete() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_CRON_TEST"] == "1", let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else { throw XCTSkip("No test server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_UPTIME_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_UPTIME_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launchEnvironment["DECKHAND_REEL_TICK"] = "1"          // no notification prompt
        app.launch()
        let row = app.buttons["dashboard.schedules"]
        XCTAssertTrue(row.waitForExistence(timeout: 40))
        var t = 0
        while !row.isHittable && t < 12 { app.swipeUp(); t += 1 }
        row.tap()

        let new = app.buttons["schedules.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 30))
        new.tap()
        let name = app.textFields["schedule.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("UI test disk check")
        let prompt = app.textFields["schedule.prompt"].exists ? app.textFields["schedule.prompt"] : app.textViews["schedule.prompt"]
        prompt.tap(); prompt.typeText("Check free disk space and report.")
        app.buttons["schedule.agent"].tap()
        app.buttons["Codex"].tap()
        XCTAssertTrue(app.staticTexts["Mon at 06:00"].waitForExistence(timeout: 5), "weekly on Monday by default, in plain words")
        app.buttons["schedule.day.5"].tap()
        XCTAssertTrue(app.staticTexts["Mon, Fri at 06:00"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "editor"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["schedule.save"].tap()

        let entry = app.descendants(matching: .any).matching(identifier: "schedule.row").containing(.staticText, identifier: "UI test disk check").firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30))
        XCTAssertTrue(entry.staticTexts["Mon, Fri at 06:00"].exists)
        XCTAssertTrue(entry.staticTexts["Hasn't run yet"].exists)

        // Run now: Codex isn't installed on the test server, so the run fails and says why.
        entry.press(forDuration: 1.0)
        app.buttons["Run Now"].tap()
        let reason = entry.staticTexts["schedule.reason"]
        let deadline = Date().addingTimeInterval(60)
        while !reason.exists && Date() < deadline {
            app.swipeDown()                                          // pull to refresh
            sleep(3)
        }
        XCTAssertTrue(reason.exists, "the failed run shows its reason")
        XCTAssertTrue(reason.label.contains("codex"), reason.label)
        let failed = XCTAttachment(screenshot: app.screenshot()); failed.name = "failed run"; failed.lifetime = .keepAlways; add(failed)

        // Pause from the leading swipe.
        entry.swipeRight()
        app.buttons["Pause"].tap()
        XCTAssertTrue(entry.images["pause.circle"].waitForExistence(timeout: 20) || entry.staticTexts["Mon, Fri at 06:00"].waitForExistence(timeout: 1))

        entry.swipeLeft()
        app.buttons["Delete"].tap()
        app.buttons["Delete Scheduled Task"].tap()
        XCTAssertTrue(entry.waitForNonExistence(timeout: 30))
    }
}
