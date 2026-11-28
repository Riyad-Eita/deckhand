import XCTest

/// An own-key task moves to the server after a consent that says where the key goes (no server needed for this part).
final class RunOnServerUITests: XCTestCase {
    func testConsentThenOnTheServer() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "DECKHAND_RESET": "1", "DECKHAND_SEED_SKIPAUTH": "1", "DECKHAND_SEED_TRUST": "1",
            "DECKHAND_SEED_HOST": "server.invalid", "DECKHAND_SEED_USER": "me", "DECKHAND_SEED_PASSWORD": "stand-in",
            "DECKHAND_SEED_NAME": "web-1", "DECKHAND_SEED_APIKEY": "stand-in-key", "DECKHAND_SEED_EMPTYTASK": "1",
        ]
        app.launch()
        let menu = app.buttons["chat.runOnServer"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        menu.tap()
        let toggle = app.switches["Keep running on the server"].exists ? app.switches["Keep running on the server"] : app.buttons["Keep running on the server"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        let send = app.buttons["Send for these tasks"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let consent = XCTAttachment(screenshot: app.screenshot()); consent.name = "consent"; consent.lifetime = .keepAlways; add(consent)
        send.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'on the server'")).firstMatch.waitForExistence(timeout: 5))
        let on = XCTAttachment(screenshot: app.screenshot()); on.name = "on-server"; on.lifetime = .keepAlways; add(on)
    }
}
