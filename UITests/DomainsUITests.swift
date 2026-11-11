import XCTest

/// Domains on a disposable server. `testConflict` with nginx on port 80; `testAddAndRemove` after nginx is stopped
/// (a service answers on 127.0.0.1:8088).
final class DomainsUITests: XCTestCase {
    private func open() throws -> (XCUIApplication, String) {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"], env["DECKHAND_DOMAIN_TEST"] != nil else {
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
        let row = app.buttons["dashboard.domains"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 8 { app.swipeUp(); tries += 1 }
        row.tap()
        let pw = app.secureTextFields.firstMatch
        XCTAssertTrue(pw.waitForExistence(timeout: 20))
        pw.typeText(password)
        app.alerts.buttons["Continue"].tap()
        return (app, password)
    }

    private func fill(_ app: XCUIApplication) {
        let add = app.buttons["domains.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        add.tap()
        let name = app.textFields["domain.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap(); name.typeText("shop.test")
        let up = app.textFields["domain.upstream"]
        up.tap(); up.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        up.typeText("127.0.0.1:8088")
        app.switches["domain.internal"].switches.firstMatch.tap()
        app.buttons["domain.check"].tap()
    }

    func testConflict() throws {
        let (app, _) = try open()
        fill(app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "already uses port 80")).firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["domain.save"].isEnabled)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "conflict"; a.lifetime = .keepAlways; add(a)
    }

    func testAddAndRemove() throws {
        let (app, _) = try open()
        fill(app)
        let save = app.buttons["domain.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 30))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: save)
        wait(for: [enabled], timeout: 30)
        save.tap()
        let apply = app.buttons["Apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        apply.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 300))
        done.tap()
        let row = app.descendants(matching: .any).matching(identifier: "domain.shop.test").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "valid until")).firstMatch.waitForExistence(timeout: 30))
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "served"; a.lifetime = .keepAlways; add(a)
        app.cells.containing(.any, identifier: "domain.shop.test").firstMatch.swipeLeft()
        app.buttons["Remove"].firstMatch.tap()
        app.buttons["Apply"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 120))
        app.buttons["Done"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        wait(for: [gone], timeout: 60)
    }
}
