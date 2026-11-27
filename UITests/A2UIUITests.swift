import XCTest

/// A view the agent drew with A2UI shows natively in the chat; a tap on its button becomes the user's next message.
/// No server or model is needed: the seeded server doesn't exist and the key is a stand-in, so the run that follows
/// fails, after the tap has been sent.
final class A2UIUITests: XCTestCase {
    func testAgentViewRendersAndATapIsSent() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "DECKHAND_RESET": "1", "DECKHAND_SEED_SKIPAUTH": "1", "DECKHAND_SEED_TRUST": "1",
            "DECKHAND_SEED_HOST": "server.invalid", "DECKHAND_SEED_USER": "me", "DECKHAND_SEED_PASSWORD": "stand-in",
            "DECKHAND_SEED_NAME": "web-1", "DECKHAND_SEED_APIKEY": "stand-in-key", "DECKHAND_SEED_A2UI": "1",
        ]
        app.launch()

        let surface = app.descendants(matching: .any)["a2ui.surface.attention-1"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["nginx.service"].exists)
        let note = app.textFields.firstMatch
        XCTAssertTrue(note.exists)
        shot(app, "view")

        let restart = app.buttons["Restart"].firstMatch
        XCTAssertTrue(restart.exists)
        restart.tap()
        // The tap arrives as the user's message, readable, without the A2UI block.
        let sent = app.staticTexts["Restart nginx"].firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'a2ui-action'")).firstMatch.exists)
        shot(app, "tapped")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
}
