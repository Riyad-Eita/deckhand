import XCTest

/// Snippets (TEST_RUNNER_DECKHAND_UPTIME_*): one with a placeholder is made in the terminal, filled in and run (it
/// writes /tmp/dh-snippet-test.txt on the server — the harness checks and removes it); a command from a seeded task
/// is saved from its card and shows up in the terminal's list.
final class SnippetsUITests: XCTestCase {
    func testMakeFillRunAndSaveFromChat() throws {
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
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "secrets|"
        app.launch()

        // From the seeded task: save its command.
        let card = app.staticTexts["$ cat .env"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 40))
        card.tap()
        let save = app.buttons["toolCard.snippet"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(app.buttons["snippet.save"].waitForExistence(timeout: 5))
        app.buttons["snippet.save"].tap()

        // Back to the server, terminal → snippets.
        app.navigationBars.buttons.firstMatch.tap()
        let terminal = app.buttons["Terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.tap()
        let open = app.buttons["terminal.snippets"]
        XCTAssertTrue(open.waitForExistence(timeout: 30))
        open.tap()
        XCTAssertTrue(app.buttons["snippet.cat .env"].waitForExistence(timeout: 5), "saved from the chat")

        app.buttons["snippet.new"].tap()
        app.textFields["snippet.title"].tap()
        app.textFields["snippet.title"].typeText("Write word")
        let command = app.textViews["snippet.command"].exists ? app.textViews["snippet.command"] : app.textFields["snippet.command"]
        command.tap()
        command.typeText("echo deckhand-{{word:hello}} > /tmp/dh-snippet-test.txt")
        app.buttons["snippet.save"].tap()

        let row = app.buttons["snippet.Write word"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let list = XCTAttachment(screenshot: app.screenshot()); list.name = "list"; list.lifetime = .keepAlways; add(list)
        row.tap()
        let value = app.textFields["snippet.value.word"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        value.typeText("snippet")
        XCTAssertEqual(app.staticTexts["snippet.preview"].label, "echo deckhand-snippet > /tmp/dh-snippet-test.txt")
        let fill = XCTAttachment(screenshot: app.screenshot()); fill.name = "fill"; fill.lifetime = .keepAlways; add(fill)
        app.buttons["snippet.run"].tap()
        sleep(3)
        let t = XCTAttachment(screenshot: app.screenshot()); t.name = "terminal"; t.lifetime = .keepAlways; add(t)
    }
}
