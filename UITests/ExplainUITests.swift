import XCTest

/// "Explain" for terminal output and tool results (TEST_RUNNER_DECKHAND_UPTIME_*). The explanation is canned
/// (DECKHAND_SEED_EXPLAIN) except in the last test, which reports whether this simulator has the on-device model.
final class ExplainUITests: XCTestCase {
    func launch(_ run: String, canned: Bool = true) throws -> XCUIApplication {
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
        app.launchEnvironment["DECKHAND_SEED_RUN"] = run
        if canned { app.launchEnvironment["DECKHAND_SEED_EXPLAIN"] = "The folder /nope doesn't exist. Check the path or create it first." }
        app.launch()
        return app
    }

    func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }

    func testTerminalExplainAndFix() throws {
        let app = try launch("terminal|")
        let explain = app.buttons["terminal.explain"]
        XCTAssertTrue(explain.waitForExistence(timeout: 30))
        sleep(3)
        app.typeText("ls /nope\n")
        sleep(2)
        explain.tap()
        XCTAssertTrue(app.descendants(matching: .any)["explain.answer"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'No such file'")).firstMatch.exists, "terminal text missing")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'On this iPhone'")).firstMatch.exists)
        shot(app, "terminal")
        app.buttons["explain.fix"].tap()
        XCTAssertTrue(app.buttons["Codex on the server"].waitForExistence(timeout: 10))
    }

    func testToolOutputExplainAndFixInTheChat() throws {
        let app = try launch("secrets|")
        let card = app.buttons.containing(NSPredicate(format: "label CONTAINS 'cat .env'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        let explain = app.buttons["toolCard.explain"]
        XCTAssertTrue(explain.waitForExistence(timeout: 10))
        explain.tap()
        XCTAssertTrue(app.descendants(matching: .any)["explain.answer"].waitForExistence(timeout: 20))
        shot(app, "toolcard")
        app.buttons["explain.fix"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Fix this problem'")).firstMatch.waitForExistence(timeout: 15))
    }

    func testRealOnDeviceModelIfThere() throws {
        let app = try launch("terminal|", canned: false)
        let explain = app.buttons["terminal.explain"]
        XCTAssertTrue(explain.waitForExistence(timeout: 30))
        sleep(3)
        app.typeText("ls /nope\n")
        sleep(2)
        explain.tap()
        let answer = app.descendants(matching: .any)["explain.answer"]
        let none = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Explanations need'")).firstMatch
        var t = 0
        while !answer.exists && !none.exists && t < 90 { sleep(1); t += 1 }
        shot(app, "ondevice")
        let failed = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'The on-device model couldn'")).firstMatch
        while !answer.exists && !none.exists && !failed.exists && t < 90 { sleep(1); t += 1 }
        if none.exists { throw XCTSkip("This simulator has no on-device model (and no key): the fallback text is shown") }
        if failed.exists { throw XCTSkip("The simulator reports an on-device model that can't answer: the plain explanation is shown") }
        XCTAssertTrue(answer.exists, "no answer after 90 s")
    }
}
