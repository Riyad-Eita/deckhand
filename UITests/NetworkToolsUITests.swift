import XCTest

/// Network tools on the disposable server (TEST_RUNNER_DECKHAND_UPTIME_*): DNS from the server, a port check from
/// the iPhone, and handing the result to an agent.
final class NetworkToolsUITests: XCTestCase {
    func testServerAndPhone() throws {
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
        let row = app.buttons["dashboard.network"]
        XCTAssertTrue(row.waitForExistence(timeout: 40))
        var t = 0
        while !row.isHittable && t < 10 { app.swipeUp(); t += 1 }
        row.tap()

        app.buttons["DNS"].tap()
        let target = app.textFields["net.target"]
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.tap(); target.typeText("github.com")
        app.buttons["net.run"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'DNS · github.com · from sandbox'")).firstMatch.waitForExistence(timeout: 60))
        let s1 = XCTAttachment(screenshot: app.screenshot()); s1.name = "dns"; s1.lifetime = .keepAlways; add(s1)

        app.buttons["Port"].tap()
        app.buttons["This iPhone"].tap()
        app.buttons["net.run"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Open ('")).firstMatch.waitForExistence(timeout: 30))
        let s2 = XCTAttachment(screenshot: app.screenshot()); s2.name = "port"; s2.lifetime = .keepAlways; add(s2)

        let ask = app.buttons["net.ask"]
        t = 0
        while !ask.isHittable && t < 5 { app.swipeUp(); t += 1 }
        ask.tap()
        XCTAssertTrue(app.buttons["Codex on the server"].waitForExistence(timeout: 10))
    }
}
