import XCTest

/// Editing files by hand (TEST_RUNNER_DECKHAND_UPTIME_*, DECKHAND_EDITOR_TEST=1). The harness puts ~/dh-edit/app.conf
/// (the login's) and ~/dh-edit/root.conf (owned by root) on the server: the first is edited with undo/redo and saved,
/// the second needs "Save as root" with the sudo password. The harness checks both files afterwards.
final class FileEditorUITests: XCTestCase {
    func testEditUndoSaveAndSaveAsRoot() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_EDITOR_TEST"] == "1", let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else {
            throw XCTSkip("No test server")
        }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_UPTIME_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_UPTIME_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launch()
        let server = app.staticTexts["sandbox"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.tap()
        app.buttons["Server"].tap()
        let files = app.buttons["dashboard.files"]
        XCTAssertTrue(files.waitForExistence(timeout: 40))
        files.tap()
        let folder = app.staticTexts["dh-edit"]
        var t = 0
        while !folder.waitForExistence(timeout: 3) && t < 6 { app.swipeUp(); t += 1 }
        folder.tap()

        func edit(_ file: String, append: String) -> XCUIElement {
            app.staticTexts[file].tap()
            let editButton = app.buttons["viewer.edit"]
            XCTAssertTrue(editButton.waitForExistence(timeout: 20))
            editButton.tap()
            let text = app.textViews["editor.text"]
            XCTAssertTrue(text.waitForExistence(timeout: 20))
            // Cursor to the end: tap below the text.
            text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
            text.typeText(append)
            return text
        }

        // The login's file: undo, redo, save.
        let text = edit("app.conf", append: "workers = 4\n")
        XCTAssertTrue((text.value as? String ?? "").contains("workers = 4"))
        sleep(2)
        app.buttons["editor.undo"].tap()
        XCTAssertFalse((text.value as? String ?? "").contains("workers = 4"))
        app.buttons["Redo"].tap()
        XCTAssertTrue((text.value as? String ?? "").contains("workers = 4"))
        let e = XCTAttachment(screenshot: app.screenshot()); e.name = "editor"; e.lifetime = .keepAlways; add(e)
        app.buttons["editor.save"].tap()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 20))
        app.buttons["Done"].tap()
        app.navigationBars.buttons.firstMatch.tap()

        // A root-owned file: Save as root.
        _ = edit("root.conf", append: "# edited by hand\n")
        app.buttons["editor.save"].tap()
        let asRoot = app.alerts.buttons["Save as root"]
        XCTAssertTrue(asRoot.waitForExistence(timeout: 20))
        asRoot.tap()
        let pw = app.secureTextFields.firstMatch
        if pw.waitForExistence(timeout: 15) { pw.typeText(password); app.alerts.buttons["Continue"].tap() }
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 60))
        app.buttons["Done"].tap()
    }
}
