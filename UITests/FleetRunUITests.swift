import XCTest

/// One command on two servers (TEST_RUNNER_DECKHAND_UPTIME_*): the test server answers, a second one that can't be
/// reached reports its error — side by side.
final class FleetRunUITests: XCTestCase {
    func testRunOnTwoServers() throws {
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
        app.launchEnvironment["DECKHAND_SEED_EXTRA"] = "offline-box|example.invalid|me"
        app.launch()

        let fleet = app.buttons["home.fleet"]
        XCTAssertTrue(fleet.waitForExistence(timeout: 20))
        fleet.tap()
        app.buttons["fleet.server.sandbox"].tap()
        app.buttons["fleet.server.offline-box"].tap()
        app.buttons["fleet.quick"].tap()
        app.buttons["Uptime and load"].tap()
        app.buttons["fleet.run"].tap()
        let ok = app.descendants(matching: .any)["fleet.result.sandbox"]
        XCTAssertTrue(ok.waitForExistence(timeout: 30))
        XCTAssertTrue(ok.staticTexts.containing(NSPredicate(format: "label CONTAINS 'load average'")).firstMatch.waitForExistence(timeout: 30))
        let bad = app.descendants(matching: .any)["fleet.result.offline-box"]
        XCTAssertTrue(bad.waitForExistence(timeout: 5))
        var t = 0
        while bad.descendants(matching: .activityIndicator).firstMatch.exists && t < 30 { sleep(1); t += 1 }
        XCTAssertFalse(bad.staticTexts.containing(NSPredicate(format: "label CONTAINS 'load average'")).firstMatch.exists)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "fleet"; s.lifetime = .keepAlways; add(s)
    }
}
