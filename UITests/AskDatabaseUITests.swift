import XCTest

/// Asking a database in plain language on the disposable server (Postgres `shop`, orders 42 and 7). The model step
/// is replaced by a canned query (DECKHAND_SEED_ASK_SQL) — the query is shown before it runs, runs read-only and the
/// result shows as a table; a writing query is refused.
final class AskDatabaseUITests: XCTestCase {
    func testAskShowsQueryThenRunsReadOnly() throws {
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
        app.launchEnvironment["DECKHAND_SEED_ASK_SQL"] = "select id, total from orders order by total desc"
        app.launch()
        let row = app.buttons["dashboard.databases"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 8 { app.swipeUp(); tries += 1 }
        row.tap()
        let shop = app.buttons["dbb.shop"]
        XCTAssertTrue(shop.waitForExistence(timeout: 60))
        shop.tap()
        let ask = app.buttons["dbb.ask"]
        XCTAssertTrue(ask.waitForExistence(timeout: 30))
        ask.tap()

        let question = app.textFields["ask.question"].exists ? app.textFields["ask.question"] : app.textViews["ask.question"]
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        question.tap(); question.typeText("Which orders are the biggest?")
        app.buttons["ask.write"].tap()
        let sql = app.textViews["ask.sql"]
        XCTAssertTrue(sql.waitForExistence(timeout: 10))
        XCTAssertEqual(sql.value as? String, "select id, total from orders order by total desc")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '42'")).count == 0, "ran before asked")
        let s1 = XCTAttachment(screenshot: app.screenshot()); s1.name = "query"; s1.lifetime = .keepAlways; add(s1)

        app.buttons["ask.run"].tap()
        XCTAssertTrue(app.staticTexts["42"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["7"].exists)
        let s2 = XCTAttachment(screenshot: app.screenshot()); s2.name = "result"; s2.lifetime = .keepAlways; add(s2)

        // A writing query can't run here.
        sql.tap()
        sql.typeText("; delete from orders")
        XCTAssertFalse(app.buttons["ask.run"].isEnabled)
    }
}
