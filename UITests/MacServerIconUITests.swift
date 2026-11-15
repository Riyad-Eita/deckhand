import XCTest

/// A Mac added as a server shows a laptop icon in the list instead of the server rack.
final class MacServerIconUITests: XCTestCase {
    func testMacShowsLaptopIcon() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["DECKHAND_RESET": "1", "DECKHAND_SEED_SKIPAUTH": "1",
                                 "DECKHAND_SEED_EXTRA": "studio|studio.local|me|mac;web|web.example.com|deploy"]
        app.launch()
        let mac = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'studio,'")).firstMatch
        XCTAssertTrue(mac.waitForExistence(timeout: 20))
        XCTAssertTrue(mac.images["laptopcomputer"].exists, mac.debugDescription)
        let linux = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'web,'")).firstMatch
        XCTAssertTrue(linux.images["server.rack"].exists)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "list"; a.lifetime = .keepAlways; add(a)
    }

    /// An unreachable Mac explains that it may be asleep.
    func testUnreachableMacHintsAtSleep() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["DECKHAND_RESET": "1", "DECKHAND_SEED_SKIPAUTH": "1",
                                 "DECKHAND_SEED_EXTRA": "studio|studio.invalid|me|mac"]
        app.launch()
        let mac = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'studio,'")).firstMatch
        XCTAssertTrue(mac.waitForExistence(timeout: 20))
        mac.tap()
        let server = app.buttons["Server"].firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        server.tap()
        XCTAssertTrue(app.descendants(matching: .any)["server.macAsleep"].firstMatch.waitForExistence(timeout: 60))
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "asleep"; a.lifetime = .keepAlways; add(a)
    }
}
