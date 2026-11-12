import XCTest

/// Scheduled jobs on the disposable server (TEST_RUNNER_DECKHAND_UPTIME_*, DECKHAND_CRON_TEST=1): a new weekly job
/// from the builder (no cron syntax), reopened with the same schedule, then deleted.
final class CronEditorUITests: XCTestCase {
    func testNewEditDelete() throws {
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
        app.launch()
        let row = app.buttons["dashboard.cron"]
        XCTAssertTrue(row.waitForExistence(timeout: 40))
        var t = 0
        while !row.isHittable && t < 10 { app.swipeUp(); t += 1 }
        row.tap()

        let new = app.buttons["cron.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 30))
        new.tap()
        let cmd = app.textFields["cron.command"].exists ? app.textFields["cron.command"] : app.textViews["cron.command"]
        XCTAssertTrue(cmd.waitForExistence(timeout: 5))
        cmd.tap(); cmd.typeText("echo dh-ui-edit")
        app.buttons["cron.frequency"].tap()
        app.buttons["On certain weekdays"].tap()
        app.buttons["cron.day.5"].tap()                                    // Mon is preselected, add Fri
        XCTAssertTrue(app.staticTexts["Mon, Fri at 03:00"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0 3 * * 1,5"].exists)
        let s1 = XCTAttachment(screenshot: app.screenshot()); s1.name = "editor"; s1.lifetime = .keepAlways; add(s1)
        app.buttons["cron.save"].tap()

        let job = app.descendants(matching: .any).matching(identifier: "cron.job").containing(.staticText, identifier: "echo dh-ui-edit").firstMatch
        XCTAssertTrue(job.waitForExistence(timeout: 30))
        XCTAssertTrue(job.staticTexts["Mon, Fri at 03:00"].exists)
        job.staticTexts["echo dh-ui-edit"].tap()
        XCTAssertTrue(app.staticTexts["0 3 * * 1,5"].waitForExistence(timeout: 5), "editor reopened with the same schedule")
        app.buttons["Cancel"].tap()

        job.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(job.waitForNonExistence(timeout: 30))
    }
}
