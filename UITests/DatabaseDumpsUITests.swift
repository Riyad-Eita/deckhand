import XCTest

/// Database dumps on a disposable server with a Postgres database `shop` the login user can reach.
final class DatabaseDumpsUITests: XCTestCase {
    func testDumpAndTestRestore() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"], env["DECKHAND_DB_TEST"] != nil else {
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
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()
        let row = app.buttons["dashboard.dbdumps"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 8 { app.swipeUp(); tries += 1 }
        row.tap()
        XCTAssertTrue(app.switches["db.shop"].waitForExistence(timeout: 60))
        shot(app, "found")
        let save = app.buttons["db.save"]
        var t = 0
        while !save.isHittable && t < 6 { app.swipeUp(); t += 1 }
        save.tap()
        let dump = app.cells.containing(.any, identifier: "db.dump").firstMatch
        let anyDump = app.descendants(matching: .any).matching(identifier: "db.dump").firstMatch
        XCTAssertTrue(anyDump.waitForExistence(timeout: 120) || dump.exists)
        shot(app, "dumps")
        anyDump.swipeLeft()
        app.buttons["Test"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Test restore worked'")).firstMatch.waitForExistence(timeout: 120))
        shot(app, "tested")
        let stop = app.buttons["Stop database dumps"]
        t = 0
        while !stop.isHittable && t < 8 { app.swipeUp(); t += 1 }
        stop.tap()
        XCTAssertTrue(app.switches["db.shop"].waitForExistence(timeout: 60))
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
