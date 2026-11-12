import XCTest

/// Backups on a disposable test server: set up with a folder target, see the password, wait for the first
/// snapshot, restore a file into a new folder, stop the backups.
final class BackupsUITests: XCTestCase {
    func testSetUpBrowseRestore() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"], let base = env["DECKHAND_BACKUP_REPO"] else {
            throw XCTSkip("No test server")
        }
        // A new folder each run: a repository left by an earlier run has a password this run doesn't know.
        let repo = base + "-" + String(Int(Date().timeIntervalSince1970))
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_UPTIME_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_UPTIME_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()
        let row = app.buttons["dashboard.backups"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 8 { app.swipeUp(); tries += 1 }
        row.tap()

        let kind = app.buttons["backup.kind"]
        let leftover = app.buttons["Stop backups"]
        var w = 0
        while !kind.exists && !leftover.exists && w < 30 { sleep(1); w += 1 }
        // A run that failed halfway left backups on: stop them first.
        if leftover.exists && !kind.exists {
            while !leftover.isHittable && w < 40 { app.swipeUp(); w += 1 }
            leftover.tap()
        }
        XCTAssertTrue(kind.waitForExistence(timeout: 60))
        kind.tap()
        app.buttons["A folder on this server"].firstMatch.tap()
        let folder = app.textFields["backup.folder"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.tap(); folder.typeText(repo + "\n")
        shot(app, "wizard")
        let setup = app.buttons["backup.setup"]
        var t = 0
        while (!setup.isHittable || setup.frame.maxY > app.frame.maxY - 80) && t < 6 { app.swipeUp(); t += 1 }
        setup.tap()
        XCTAssertTrue(app.staticTexts["backup.password"].waitForExistence(timeout: 240))
        app.buttons["I've saved it"].tap()

        let snap = app.buttons["backup.snapshot"].firstMatch
        t = 0
        while !snap.exists && t < 20 { sleep(5); app.buttons["Refresh"].tap(); t += 1 }
        XCTAssertTrue(snap.waitForExistence(timeout: 10))
        shot(app, "overview")
        snap.tap()
        let file = app.staticTexts[".profile"]
        XCTAssertTrue(file.waitForExistence(timeout: 60))
        file.swipeLeft()
        app.buttons["Restore"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Restored to'")).firstMatch.waitForExistence(timeout: 120))
        shot(app, "restored")
        app.navigationBars.buttons.firstMatch.tap()
        let stop = app.buttons["Stop backups"]
        t = 0
        while !stop.isHittable && t < 8 { app.swipeUp(); t += 1 }
        stop.tap()
        XCTAssertTrue(app.staticTexts["What to back up"].waitForExistence(timeout: 60) || app.buttons["backup.kind"].waitForExistence(timeout: 5))
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
