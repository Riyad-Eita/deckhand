import XCTest

/// Tripwires on a disposable test server. Run `testPlant`, open a decoy on the server, then run `testAlertAndRemove`.
final class TripwireUITests: XCTestCase {
    private func open() throws -> (XCUIApplication, String) {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"], let topic = env["DECKHAND_TRIP_TOPIC"] else {
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
        app.launchEnvironment["DECKHAND_SEED_NTFY"] = topic
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()
        let row = app.buttons["dashboard.tripwires"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 14 { app.swipeUp(); tries += 1 }
        row.tap()
        let pw = app.secureTextFields.firstMatch
        XCTAssertTrue(pw.waitForExistence(timeout: 20))
        pw.typeText(password)
        app.alerts.buttons["Continue"].tap()
        return (app, password)
    }

    func testPlant() throws {
        let (app, _) = try open()
        let plant = app.buttons["tripwire.plant"]
        XCTAssertTrue(plant.waitForExistence(timeout: 30))
        var t = 0
        while !plant.isHittable && t < 6 { app.swipeUp(); t += 1 }
        plant.tap()
        let apply = app.buttons["Apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        apply.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 120))
        done.tap()
        XCTAssertTrue(app.staticTexts["Tripwires are armed"].waitForExistence(timeout: 30))
    }

    func testAlertAndRemove() throws {
        let (app, _) = try open()
        let hit = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'opened by'")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 30))
        sleep(1)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "alert"; a.lifetime = .keepAlways; add(a)
        let remove = app.buttons["Remove tripwires"]
        var t = 0
        while !remove.isHittable && t < 6 { app.swipeUp(); t += 1 }
        remove.tap()
        app.buttons["Apply"].tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 120))
        done.tap()
        XCTAssertTrue(app.buttons["tripwire.plant"].waitForExistence(timeout: 30))
    }
}
