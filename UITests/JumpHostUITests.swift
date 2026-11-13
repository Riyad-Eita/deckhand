import XCTest

/// A server behind a jump host (TEST_RUNNER_DECKHAND_UPTIME_*): the test server is the jump host, and "inner" is its
/// own sshd on 127.0.0.1:22 — reachable only through the jump. Its dashboard loads and a terminal opens.
final class JumpHostUITests: XCTestCase {
    func testThroughJumpHost() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else { throw XCTSkip("No test server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_UPTIME_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_UPTIME_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "bastion"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_JUMP_TARGET"] = "inner|127.0.0.1|22"
        app.launch()

        let inner = app.staticTexts["inner"]
        XCTAssertTrue(inner.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label ENDSWITH 'via bastion'")).firstMatch.exists)
        let home = XCTAttachment(screenshot: app.screenshot()); home.name = "home"; home.lifetime = .keepAlways; add(home)
        inner.tap()
        app.buttons["Server"].tap()
        XCTAssertTrue(app.buttons["dashboard.files"].waitForExistence(timeout: 40))
        // Live stats prove the connection works: the CPU tile shows the core count.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label ENDSWITH 'cores'")).firstMatch.waitForExistence(timeout: 30))
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "dashboard"; s.lifetime = .keepAlways; add(s)
        // The terminal's contents aren't exposed to XCUITest; the screenshot shows the shell prompt.
        app.buttons["Terminal"].tap()
        sleep(4)
        let t = XCTAttachment(screenshot: app.screenshot()); t.name = "terminal"; t.lifetime = .keepAlways; add(t)
    }
}
