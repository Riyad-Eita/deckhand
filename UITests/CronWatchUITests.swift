import XCTest

/// Cron heartbeats on the disposable server (TEST_RUNNER_DECKHAND_UPTIME_*, DECKHAND_CRON_TEST=1 with a job
/// `*/30 * * * * echo dh-ui-job` in the user's crontab): watch it, see it waiting for its first run, stop watching.
final class CronWatchUITests: XCTestCase {
    func testWatchAndUnwatch() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_CRON_TEST"] == "1", let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else { throw XCTSkip("No test job") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_UPTIME_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_UPTIME_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()
        let row = app.buttons["dashboard.cron"]
        XCTAssertTrue(row.waitForExistence(timeout: 40))
        var t = 0
        while !row.isHittable && t < 10 { app.swipeUp(); t += 1 }
        row.tap()
        XCTAssertTrue(app.staticTexts["Every 30 minutes"].waitForExistence(timeout: 30))
        // Only the user's own job is listed (Deckhand's own cron jobs are not).
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '.deckhand/'")).firstMatch.exists)
        let job = app.descendants(matching: .any).matching(identifier: "cron.job").containing(.staticText, identifier: "echo dh-ui-job").firstMatch
        job.buttons["cron.watch"].tap()
        XCTAssertTrue(app.staticTexts["Watching — no run yet"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["echo dh-ui-job"].exists, "the original command should show, not the wrapper")
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "watched"; s.lifetime = .keepAlways; add(s)
        job.buttons["cron.unwatch"].tap()
        XCTAssertTrue(job.buttons["cron.watch"].waitForExistence(timeout: 30))
    }
}
