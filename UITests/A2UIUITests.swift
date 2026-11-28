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

    /// A server session (here Codex) writes its view as a ```a2ui block: the chat draws it in place of the block,
    /// a broken block says so, and a tap goes back to the session. The view is one Codex really wrote for this prompt.
    func testViewFromASessionReply() throws {
        let view = #"{"messages":[{"version":"1.0","createSurface":{"surfaceId":"tmp_cleanup_1","dataModel":{"selection":[]},"components":[{"id":"root","component":"Card","child":"main"},{"id":"main","component":"Column","children":["title","summary","picker","clean_button"],"align":"stretch"},{"id":"title","component":"Text","text":"**Largest entries in `/tmp`**"},{"id":"summary","component":"Text","variant":"caption","text":"`/tmp/build-cache` — 10.3 GB\n\nThe other three entries report 0 KB."},{"id":"picker","component":"ChoicePicker","label":"Select entries to clean up","variant":"multipleSelection","options":[{"label":"/tmp/build-cache (10.3 GB)","value":"/tmp/build-cache"},{"label":"/tmp/ipc-1 (0 KB)","value":"/tmp/ipc-1"},{"label":"/tmp/ipc-2 (0 KB)","value":"/tmp/ipc-2"},{"label":"/tmp/ipc-3 (0 KB)","value":"/tmp/ipc-3"}],"value":{"@path":"/selection"}},{"id":"clean_button","component":"Button","child":"clean_text","variant":"primary","action":{"event":{"name":"clean_tmp_entries","userMessage":"Clean the selected /tmp entries","context":{"entries":{"@path":"/selection"}}}}},{"id":"clean_text","component":"Text","text":"Clean selected entries"}]}}]}"#
        let reply = "Here are the four largest entries in `/tmp`.\n\n```a2ui\n\(view)\n```\n\nAnd one view that went wrong:\n\n```a2ui\n{\"messages\": [\n```"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "DECKHAND_RESET": "1", "DECKHAND_SEED_SKIPAUTH": "1", "DECKHAND_SEED_TRUST": "1",
            "DECKHAND_SEED_HOST": "server.invalid", "DECKHAND_SEED_USER": "me", "DECKHAND_SEED_PASSWORD": "stand-in",
            "DECKHAND_SEED_NAME": "web-1", "DECKHAND_SEED_A2UI_REPLY": reply,
            "DECKHAND_SEED_A2UI_PROMPT": "List the 4 largest entries in /tmp, and let me pick which ones to clean up.",
        ]
        app.launch()

        let surface = app.descendants(matching: .any)["a2ui.surface.tmp_cleanup_1"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Here are the four largest entries in /tmp."].exists || app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Here are the four largest'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'createSurface'")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["a2ui.problem"].firstMatch.exists)
        shot(app, "session-view")

        let clean = app.buttons["Clean selected entries"].firstMatch
        XCTAssertTrue(clean.exists)
        clean.tap()
        XCTAssertTrue(app.staticTexts["Clean the selected /tmp entries"].firstMatch.waitForExistence(timeout: 10))
        shot(app, "session-tapped")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
}
