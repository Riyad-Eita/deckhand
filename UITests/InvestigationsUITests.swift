import XCTest

/// Auto-investigate and server-started runs on the disposable server (TEST_RUNNER_DECKHAND_UPTIME_*,
/// DECKHAND_CRON_TEST=1). The checker is not switched on here — it would start real agent runs — so this opens the
/// screen, then opens a run the server started by itself under Background tasks and reads it like any task.
final class InvestigationsUITests: XCTestCase {
    func testScreenAndServerStartedRun() throws {
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
        app.launchEnvironment["DECKHAND_REEL_TICK"] = "1"
        app.launch()
        let row = app.buttons["dashboard.investigate"]
        XCTAssertTrue(row.waitForExistence(timeout: 40))
        var t = 0
        while !row.isHittable && t < 15 { app.swipeUp(); t += 1 }
        row.tap()
        XCTAssertTrue(app.switches["investigate.toggle"].waitForExistence(timeout: 30))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "auto-investigate"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars.buttons.firstMatch.tap()

        let bg = app.buttons["Background tasks"].exists ? app.buttons["Background tasks"] : app.staticTexts["Background tasks"]
        t = 0
        while !bg.isHittable && t < 15 { app.swipeUp(); t += 1 }
        bg.tap()
        let done = app.staticTexts["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 30), "the server has finished runs")
        done.tap()
        // The run opens as a task, read from the start.
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 30) || app.textFields.firstMatch.waitForExistence(timeout: 5))
        let task = XCTAttachment(screenshot: app.screenshot()); task.name = "server run as task"; task.lifetime = .keepAlways; add(task)
    }
}
