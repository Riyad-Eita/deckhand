import XCTest

/// House rules on a disposable test server: protect a folder, switch on read-only mode, save, see them active; then
/// remove them again.
final class HouseRulesUITests: XCTestCase {
    func testSaveAndRemoveRules() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else { throw XCTSkip("No test server") }
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
        let row = app.buttons["dashboard.rules"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 10 { app.swipeUp(); tries += 1 }
        row.tap()
        let field = app.textFields["rules.newPath"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap(); field.typeText("/srv/db")
        app.buttons["rules.addPath"].tap()
        XCTAssertTrue(app.staticTexts["/srv/db"].waitForExistence(timeout: 5))
        app.switches["rules.readOnly"].switches.firstMatch.tap()
        let save = app.buttons["rules.save"]
        var t = 0
        while !save.isHittable && t < 8 { app.swipeUp(); t += 1 }
        save.tap()
        let active = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Active for'")).firstMatch
        t = 0
        while !active.exists && t < 8 { app.swipeDown(); t += 1; sleep(1) }
        XCTAssertTrue(active.waitForExistence(timeout: 30))
        sleep(1)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "saved"; a.lifetime = .keepAlways; add(a)
        let remove = app.buttons["Remove all rules"]
        t = 0
        while !remove.isHittable && t < 8 { app.swipeUp(); t += 1 }
        remove.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 30))
    }
}
