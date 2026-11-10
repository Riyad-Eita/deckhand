import XCTest

/// Model and effort for a Codex task: the header menu lists the models the server's Codex offers, the choice shows
/// in the header. DECKHAND_WEB_HOST/PORT/USER/KEY with Codex installed there. Nothing is sent.
final class CLIModelUITests: XCTestCase {
    func testPickModelAndEffort() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_WEB_HOST"], let key = env["DECKHAND_WEB_KEY"] else { throw XCTSkip("No server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_WEB_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_WEB_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_KEY"] = key
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "web-1"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "codex|"
        app.launch()

        let menu = app.buttons["chat.modelMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        sleep(4) // the model list loads from the server
        menu.tap()
        sleep(1)
        let m0 = XCTAttachment(screenshot: app.screenshot()); m0.name = "menu-open"; m0.lifetime = .keepAlways; add(m0)
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Model'")).firstMatch.tap()
        let gpt = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'GPT'")).firstMatch
        XCTAssertTrue(gpt.waitForExistence(timeout: 10))
        let name = gpt.label
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "menu"; s.lifetime = .keepAlways; add(s)
        gpt.tap()

        menu.tap()
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Effort'")).firstMatch.tap()
        let high = app.buttons["High"]
        XCTAssertTrue(high.waitForExistence(timeout: 5))
        high.tap()

        let header = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS 'High'", name)).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), "header shows \(name) · High")
        let h = XCTAttachment(screenshot: app.screenshot()); h.name = "header"; h.lifetime = .keepAlways; add(h)
    }
}
