import XCTest

/// The sessions list in the terminal (seeded listing, no server needed): tmux and screen sessions with their state;
/// without tmux it offers to install it.
final class TerminalSessionsUITests: XCTestCase {
    private func launch(_ sessions: String) -> XCUIApplication {
        let app = XCUIApplication()
        let now = Int(Date().timeIntervalSince1970)
        app.launchEnvironment = [
            "DECKHAND_RESET": "1", "DECKHAND_SEED_SKIPAUTH": "1", "DECKHAND_SEED_TRUST": "1",
            "DECKHAND_SEED_HOST": "server.invalid", "DECKHAND_SEED_USER": "me", "DECKHAND_SEED_PASSWORD": "stand-in",
            "DECKHAND_SEED_NAME": "sandbox",
            "DECKHAND_SEED_SESSIONS": sessions.replacingOccurrences(of: "NOW", with: "\(now)"),
        ]
        app.launch()
        let server = app.staticTexts["sandbox"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.tap()
        app.buttons["Terminal"].tap()
        let open = app.buttons["terminal.sessions"]
        XCTAssertTrue(open.waitForExistence(timeout: 30))
        open.tap()
        return app
    }

    func testListsSessions() throws {
        let app = launch("T,deckhand,1,1,NOW|T,build,3,0,NOW|S,4242.logs,Detached|HAS_TMUX|HAS_SCREEN")
        XCTAssertTrue(app.buttons["session.build"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["session.deckhand"].exists)
        XCTAssertTrue(app.buttons["session.logs"].exists)
        XCTAssertFalse(app.buttons["session.installTmux"].exists)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "sessions"; s.lifetime = .keepAlways; add(s)
    }

    func testOffersTmuxWhenMissing() throws {
        let app = launch("HAS_SCREEN")
        XCTAssertTrue(app.buttons["session.installTmux"].waitForExistence(timeout: 10))
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "install"; s.lifetime = .keepAlways; add(s)
    }
}
