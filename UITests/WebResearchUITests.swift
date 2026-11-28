import XCTest

/// A reply that searched the web shows what it looked up and its sources as links (seeded reply, no key needed).
final class WebResearchUITests: XCTestCase {
    func testSourcesShowInTheChat() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "DECKHAND_RESET": "1", "DECKHAND_SEED_SKIPAUTH": "1", "DECKHAND_SEED_TRUST": "1",
            "DECKHAND_SEED_HOST": "server.invalid", "DECKHAND_SEED_USER": "me", "DECKHAND_SEED_PASSWORD": "stand-in",
            "DECKHAND_SEED_NAME": "web-1", "DECKHAND_SEED_APIKEY": "stand-in-key", "DECKHAND_SEED_WEBREPLY": "1",
        ]
        app.launch()
        let sources = app.descendants(matching: .any)["web.sources"].firstMatch
        XCTAssertTrue(sources.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Searched the web · 2 sources"].exists)
        app.staticTexts["Searched the web · 2 sources"].tap()
        XCTAssertTrue(app.staticTexts["Changes with nginx 1.29"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["nginx 1.29 changes"].exists)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "sources"; s.lifetime = .keepAlways; add(s)
    }
}
