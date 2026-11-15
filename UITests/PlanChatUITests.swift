import XCTest

/// A plain chat with the user's own plan instead of an API key: Codex on the disposable server answers
/// (TEST_RUNNER_DECKHAND_UPTIME_*, DECKHAND_PLAN_TEST=1; a stand-in `codex` is installed there for the test, so no
/// subscription is used). The second message continues the same CLI session.
final class PlanChatUITests: XCTestCase {
    func testChatWithYourPlan() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_PLAN_TEST"] == "1", let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else { throw XCTSkip("No test server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_UPTIME_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_UPTIME_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_APIKEY"] = "invalid-test-key"
        app.launch()

        let newChat = app.buttons["home.newChat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 30))
        newChat.tap()
        app.buttons["chat.model"].tap()
        let codex = app.buttons["Codex on sandbox"]
        XCTAssertTrue(codex.waitForExistence(timeout: 5))
        codex.tap()
        XCTAssertTrue(app.staticTexts["Codex · sandbox"].waitForExistence(timeout: 5))

        let input = app.textFields["plainchat.input"].exists ? app.textFields["plainchat.input"] : app.textViews["plainchat.input"]
        input.tap(); input.typeText("Say hi.")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Hello from your plan'")).firstMatch.waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["Stop"].waitForNonExistence(timeout: 30))

        input.tap(); input.typeText("And again.")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'same session'")).firstMatch.waitForExistence(timeout: 60))
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "plan chat"; s.lifetime = .keepAlways; add(s)
    }
}
