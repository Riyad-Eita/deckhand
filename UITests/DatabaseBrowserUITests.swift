import XCTest

/// The database browser on a disposable server with Postgres `shop` (orders: 42, 7) and Redis (user:7).
final class DatabaseBrowserUITests: XCTestCase {
    func testBrowseEditQueryRedis() throws {
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
        let row = app.buttons["dashboard.databases"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 8 { app.swipeUp(); tries += 1 }
        row.tap()
        let shop = app.buttons["dbb.shop"]
        XCTAssertTrue(shop.waitForExistence(timeout: 60))
        shop.tap()
        let orders = app.buttons["table.public.orders"]
        XCTAssertTrue(orders.waitForExistence(timeout: 30))
        orders.tap()
        let cell = app.staticTexts["42"]
        XCTAssertTrue(cell.waitForExistence(timeout: 30))
        shot(app, "rows")
        cell.tap()
        let value = app.textFields["cell.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 10))
        value.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap(); value.typeText("1")   // 42 → 421
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "= '421' where")).firstMatch.waitForExistence(timeout: 5))
        shot(app, "edit")
        app.buttons["cell.save"].tap()
        app.buttons["Change it"].tap()
        XCTAssertTrue(app.staticTexts["421"].waitForExistence(timeout: 30))
        app.staticTexts["421"].tap()
        let v2 = app.textFields["cell.value"]
        XCTAssertTrue(v2.waitForExistence(timeout: 10))
        v2.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap(); v2.typeText(XCUIKeyboardKey.delete.rawValue)   // back to 42
        app.buttons["cell.save"].tap()
        app.buttons["Change it"].tap()
        XCTAssertTrue(app.staticTexts["42"].waitForExistence(timeout: 30))
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["dbb.sql"].tap()
        let editor = app.textViews["sql.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap(); editor.typeText("select count(*) as n from orders")
        app.buttons["sql.run"].tap()
        XCTAssertTrue(app.staticTexts["2"].waitForExistence(timeout: 30))
        shot(app, "sql")
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()

        let redis = app.buttons["dbb.redis"]
        XCTAssertTrue(redis.waitForExistence(timeout: 20))
        redis.tap()
        let key = app.buttons.containing(NSPredicate(format: "label CONTAINS 'user:7'")).firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 30))
        key.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Ann'")).firstMatch.waitForExistence(timeout: 30))
        shot(app, "redis")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
