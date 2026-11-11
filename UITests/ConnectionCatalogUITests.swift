import XCTest

/// Pick a server from the catalog, test it, save it.
final class ConnectionCatalogUITests: XCTestCase {
    func testAddFromCatalog() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_SCREEN"] = "connections"
        app.launch()
        let preset = app.buttons["preset.cfdocs"]
        var t = 0
        while !preset.exists && t < 8 { app.swipeUp(); t += 1 }
        XCTAssertTrue(preset.waitForExistence(timeout: 20))
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "catalog"; a.lifetime = .keepAlways; add(a)
        preset.tap()
        XCTAssertTrue(app.staticTexts["Searches Cloudflare's documentation. No account needed."].waitForExistence(timeout: 10))
        app.buttons["Test Connection"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "tool")).firstMatch.waitForExistence(timeout: 60))
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "tested"; b.lifetime = .keepAlways; add(b)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Cloudflare Docs"].waitForExistence(timeout: 10))
    }
}
