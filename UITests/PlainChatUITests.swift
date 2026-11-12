import XCTest

/// Plain chats without a server: start one from the empty home screen, switch the model from the title, send a
/// message. The key is deliberately invalid, so the provider's error comes back instead of an answer.
final class PlainChatUITests: XCTestCase {
    func testChatWithoutAServer() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_APIKEY"] = "invalid-test-key"
        app.launch()

        // Empty home screen: "Or just chat"; with servers left from other tests: "New chat" under Chats.
        let empty = app.buttons["home.justChat"], listed = app.buttons["home.newChat"]
        var t = 0
        while !empty.exists && !listed.exists && t < 20 { sleep(1); t += 1 }
        (empty.exists ? empty : listed).tap()
        XCTAssertTrue(app.staticTexts["Ask anything"].waitForExistence(timeout: 10))

        // Switch the model mid-chat from the title menu.
        app.buttons["chat.model"].tap()
        let haiku = app.buttons["claude-haiku-5-5"]
        XCTAssertTrue(haiku.waitForExistence(timeout: 5))
        haiku.tap()
        XCTAssertTrue(app.staticTexts["claude-haiku-5-5"].waitForExistence(timeout: 5))

        let input = app.textFields["plainchat.input"].exists ? app.textFields["plainchat.input"] : app.textViews["plainchat.input"]
        input.tap()
        input.typeText("Explain HTTP 502 in one sentence.")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["Explain HTTP 502 in one sentence."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Stop"].waitForNonExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '401'")).firstMatch.waitForExistence(timeout: 10))
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "chat"; s.lifetime = .keepAlways; add(s)

        // It's listed on the home screen.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Explain HTTP 502 in one sentence."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["home.newChat"].exists)
        let h = XCTAttachment(screenshot: app.screenshot()); h.name = "home"; h.lifetime = .keepAlways; add(h)
    }
}
