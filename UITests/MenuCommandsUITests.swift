import XCTest

/// Menu bar / keyboard commands (Mac, iPad) reach the home screen: DECKHAND_SEED_COMMAND fires one like a menu pick.
final class MenuCommandsUITests: XCTestCase {
    private func launch(_ command: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["DECKHAND_RESET": "1", "DECKHAND_SEED_SKIPAUTH": "1", "DECKHAND_SEED_COMMAND": command,
                                 "DECKHAND_SEED_EXTRA": "db|db.example.com|deploy;staging|staging.example.com|deploy"]
        app.launch(); return app
    }
    func testNewServer() { XCTAssertTrue(launch("newServer").navigationBars["Add Server"].waitForExistence(timeout: 15)) }
    func testImportServers() { XCTAssertTrue(launch("importServers").navigationBars["Import servers"].waitForExistence(timeout: 15)) }
    func testSettings() { XCTAssertTrue(launch("settings").navigationBars["Settings"].waitForExistence(timeout: 15)) }
    func testSearch() { XCTAssertTrue(launch("search").searchFields.firstMatch.waitForExistence(timeout: 15) || XCUIApplication().textFields.firstMatch.waitForExistence(timeout: 5)) }
}
