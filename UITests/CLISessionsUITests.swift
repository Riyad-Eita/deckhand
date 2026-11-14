import XCTest

/// Sessions from the laptop (TEST_RUNNER_DECKHAND_UPTIME_*, DECKHAND_SESSIONS_TEST=1). The harness puts a Claude Code
/// and a Codex session file (synthetic) in their places on the server: both are listed by folder, the Claude one is
/// read and continued here — the task opens with its history.
final class CLISessionsUITests: XCTestCase {
    func testListReadContinue() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_SESSIONS_TEST"] == "1", let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else {
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
        app.launch()
        let server = app.staticTexts["sandbox"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.tap()
        let entry = app.buttons["agent.sessions"]
        var t = 0
        while !(entry.exists && entry.isHittable) && t < 6 { app.swipeUp(); t += 1 }
        entry.tap()

        let claude = app.buttons["session.Fix the shop's 502"]
        XCTAssertTrue(claude.waitForExistence(timeout: 40))
        XCTAssertTrue(app.buttons["session.Add a health endpoint"].exists)
        XCTAssertTrue(app.staticTexts["/home/me/shop"].exists || app.staticTexts["/HOME/ME/SHOP"].exists)
        let list = XCTAttachment(screenshot: app.screenshot()); list.name = "sessions"; list.lifetime = .keepAlways; add(list)

        claude.tap()
        XCTAssertTrue(app.staticTexts["PHP-FPM is down; restart it."].waitForExistence(timeout: 30))
        let detail = XCTAttachment(screenshot: app.screenshot()); detail.name = "transcript"; detail.lifetime = .keepAlways; add(detail)
        app.buttons["session.continue"].tap()
        // The task opens with the session's history.
        XCTAssertTrue(app.staticTexts["Why does the shop return 502?"].waitForExistence(timeout: 15))
        let chat = XCTAttachment(screenshot: app.screenshot()); chat.name = "continued"; chat.lifetime = .keepAlways; add(chat)
    }
}
