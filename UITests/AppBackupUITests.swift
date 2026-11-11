import XCTest

/// Export an encrypted backup with secrets, wipe the app, import it again: the server is back.
final class AppBackupUITests: XCTestCase {
    func openBackup(_ app: XCUIApplication) {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let row = app.buttons["settings.appBackup"]
        var t = 0
        while !row.exists && t < 10 { app.swipeUp(); t += 1 }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
    }

    func testExportWipeImport() throws {
        let pass = "correct horse battery"
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = "export.example.com"
        app.launchEnvironment["DECKHAND_SEED_USER"] = "me"
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "carried-over"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = "not-a-real-password"
        app.launch()
        openBackup(app)
        let p1 = app.secureTextFields["backup.app.pass"]
        XCTAssertTrue(p1.waitForExistence(timeout: 10))
        p1.tap(); p1.typeText(pass)
        let p2 = app.secureTextFields["backup.app.pass2"]
        p2.tap(); p2.typeText(pass)
        app.switches["Include passwords, keys and API keys"].switches.firstMatch.tap()
        app.buttons["backup.app.export"].tap()
        XCTAssertTrue(app.staticTexts["Backup file ready, with secrets."].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["backup.app.share"].exists)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "exported"; a.lifetime = .keepAlways; add(a)
        app.terminate()

        let day = Date().formatted(.iso8601.year().month().day())
        let fresh = XCUIApplication()
        fresh.launchEnvironment["DECKHAND_RESET"] = "1"
        fresh.launchEnvironment["DECKHAND_SEED_IMPORT"] = "Deckhand backup \(day).deckhand|\(pass)"
        fresh.launch()
        XCTAssertFalse(fresh.staticTexts["carried-over"].waitForExistence(timeout: 3))
        openBackup(fresh)
        XCTAssertTrue(fresh.staticTexts["Imported 1 servers. Restart Deckhand to load the settings."].waitForExistence(timeout: 30))
        fresh.navigationBars.buttons.firstMatch.tap()
        let done = fresh.buttons["Done"]
        if done.waitForExistence(timeout: 3) { done.tap() }
        XCTAssertTrue(fresh.staticTexts["carried-over"].waitForExistence(timeout: 10))
    }
}
