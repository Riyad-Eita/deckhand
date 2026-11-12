import XCTest

/// Trends on the disposable server (TEST_RUNNER_DECKHAND_UPTIME_*): start recording, see the first sample state,
/// stop recording again.
final class MetricsHistoryUITests: XCTestCase {
    func testStartAndStopRecording() throws {
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
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()
        let trends = app.buttons["dashboard.trends"]
        XCTAssertTrue(trends.waitForExistence(timeout: 40))
        var t = 0
        while !trends.isHittable && t < 5 { app.swipeUp(); t += 1 }
        trends.tap()
        let install = app.buttons["metrics.install"], stop = app.buttons["Stop recording"]
        t = 0
        while !install.exists && !stop.exists && t < 30 { sleep(1); t += 1 }
        if install.exists { install.tap() }
        XCTAssertTrue(app.staticTexts["metrics.collecting"].waitForExistence(timeout: 30) || app.descendants(matching: .any)["metrics.chart"].exists)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "trends"; s.lifetime = .keepAlways; add(s)
        app.buttons["Memory"].tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()
        XCTAssertTrue(install.waitForExistence(timeout: 30))
    }

    /// With a week of data already on the server (DECKHAND_METRICS_DEMO=1): the 7-day chart with a spike.
    func testWeekChart() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_METRICS_DEMO"] == "1", let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else { throw XCTSkip("No demo data") }
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
        let trends = app.buttons["dashboard.trends"]
        XCTAssertTrue(trends.waitForExistence(timeout: 40))
        trends.tap()
        XCTAssertTrue(app.descendants(matching: .any)["metrics.chart"].waitForExistence(timeout: 30))
        app.buttons["7 days"].tap()
        sleep(1)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'unusual spike'")).firstMatch.exists)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "week"; s.lifetime = .keepAlways; add(s)
    }
}
