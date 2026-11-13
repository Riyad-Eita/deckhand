import XCTest

/// Auto model choice and comparing two models (TEST_RUNNER_DECKHAND_UPTIME_*, DECKHAND_ROUTER_TEST=1). The user's
/// models are Claude (with a deliberately invalid key) and a small free model on the server — on the test server a
/// stand-in for Ollama's API on port 11434. A quick question goes to the free model and shows "free"; a hard one goes
/// to Claude Opus (and comes back with the 401); the comparison runs both side by side.
final class ModelRouterUITests: XCTestCase {
    func testAutoAndCompare() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_ROUTER_TEST"] == "1", let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else {
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
        app.launchEnvironment["DECKHAND_SEED_APIKEY"] = "invalid-test-key"
        app.launchEnvironment["DECKHAND_SEED_LOCAL_MODEL"] = "qwen3:0.6b"
        app.launch()

        let newChat = app.buttons["home.newChat"]
        var t = 0
        while !(newChat.exists && newChat.isHittable) && t < 8 { if !newChat.waitForExistence(timeout: 3) { app.swipeUp() }; t += 1 }
        newChat.tap()
        app.buttons["chat.model"].tap()
        app.buttons["chat.model.auto"].tap()
        XCTAssertTrue(app.staticTexts["Auto"].waitForExistence(timeout: 5))

        func send(_ text: String) {
            let input = app.textFields["plainchat.input"].exists ? app.textFields["plainchat.input"] : app.textViews["plainchat.input"]
            input.tap()
            input.typeText(text)
            app.buttons["Send"].tap()
            XCTAssertTrue(app.buttons["Stop"].waitForNonExistence(timeout: 120))
        }

        // Quick question → the free model on the server.
        send("What's the capital of Portugal?")
        let caption = app.descendants(matching: .any).matching(identifier: "chat.caption").firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 10))
        XCTAssertTrue(caption.label.contains("qwen3:0.6b") && caption.label.contains("free"), caption.label)

        // A question that needs thinking → Claude Opus, which rejects the invalid key.
        send("Should I move our Postgres to a managed service or keep running it on the VPS? We have 40 GB of data and two people on call.")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '401'")).firstMatch.waitForExistence(timeout: 10))
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "auto"; s.lifetime = .keepAlways; add(s)

        // Compare: the free local model next to Opus.
        app.buttons["chat.model"].tap()
        app.buttons["chat.compare"].tap()
        let run = app.buttons["compare.run"]
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Auto would treat this as'")).firstMatch.exists)
        run.tap()
        let answer = app.descendants(matching: .any).matching(identifier: "compare.answer").firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 60))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "compare.cost").firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '401'")).firstMatch.waitForExistence(timeout: 30))
        let c = XCTAttachment(screenshot: app.screenshot()); c.name = "compare"; c.lifetime = .keepAlways; add(c)
    }
}
