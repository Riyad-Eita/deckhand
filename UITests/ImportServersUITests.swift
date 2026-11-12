import XCTest

/// Importing servers from an ssh config (DECKHAND_SEED_IMPORT_TEXT stands in for the file picker): both hosts are
/// found, imported, and listed; they still need a way to sign in, which the sheet says.
final class ImportServersUITests: XCTestCase {
    func testImportFromSSHConfig() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_IMPORT_TEXT"] = """
        Host web-1
          HostName 203.0.113.10
          User deploy
          Port 2222
          IdentityFile ~/.ssh/id_work
        Host db
          HostName db.example.com
        Host *
          User admin
        """
        app.launch()
        let start = app.buttons["home.import"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        XCTAssertTrue(app.buttons["import.host.web-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["import.host.db"].exists)
        XCTAssertTrue(app.staticTexts["deploy@203.0.113.10:2222"].exists)
        XCTAssertTrue(app.staticTexts["admin@db.example.com"].exists)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "preview"; s.lifetime = .keepAlways; add(s)
        app.buttons["import.go"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Imported. 2 of them need'")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["web-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["db"].exists)
    }
}
