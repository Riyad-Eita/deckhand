import XCTest

/// Plan usage (TEST_RUNNER_DECKHAND_UPTIME_*, DECKHAND_USAGE_TEST=1). The harness puts a Codex session on the server
/// whose last report says 86 % of the 5-hour limit is used: Server Tools shows it, and a Codex task warns and offers to
/// start after the reset.
final class PlanUsageUITests: XCTestCase {
    func testUsageAndStartAfterReset() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_USAGE_TEST"] == "1", let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else {
            throw XCTSkip("No test server")
        }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_UPTIME_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_UPTIME_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "secrets|"   // a Codex task
        app.launch()

        // The seeded Codex task: warning with "Start after the reset".
        let warning = app.descendants(matching: .any)["usage.warning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 40))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '86 % of the 5-hour limit used'")).firstMatch.exists)
        let start = app.buttons["usage.startAfter"]
        start.tap()
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Starts '")).firstMatch.waitForExistence(timeout: 5))
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "warning"; s.lifetime = .keepAlways; add(s)

        // Server Tools: the usage per window.
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Server Tools"].tap()
        let fiveHours = app.descendants(matching: .any)["usage.codex.300"]
        var t = 0
        while !fiveHours.waitForExistence(timeout: 3) && t < 8 { app.swipeUp(); t += 1 }
        XCTAssertTrue(fiveHours.label.contains("86"), fiveHours.label)
        let tools = XCTAttachment(screenshot: app.screenshot()); tools.name = "tools"; tools.lifetime = .keepAlways; add(tools)
    }
}
