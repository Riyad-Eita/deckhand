import XCTest

/// SSH keys (DECKHAND_KEY_HOST/PORT/USER/KEY): rotate this iPhone's key on the server, then remove a lost
/// device's key ("deckhand@Old-iPhone") everywhere.
final class KeysUITests: XCTestCase {
    func testRotateAndRemoveLostDevice() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_KEY_HOST"], let key = env["DECKHAND_KEY_KEY"] else { throw XCTSkip("No key test server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_KEY_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_KEY_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_KEY"] = key
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "web-1"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launch()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let keys = app.buttons["settings.keys"]
        var tries = 0
        while !(keys.exists && keys.isHittable) && tries < 8 { app.swipeUp(); tries += 1 }
        keys.tap()
        let lost = app.staticTexts["deckhand@Old-iPhone"]
        XCTAssertTrue(lost.waitForExistence(timeout: 30))
        app.buttons["keys.rotate"].tap()
        app.buttons["Rotate"].tap()
        XCTAssertTrue(app.staticTexts["New key"].waitForExistence(timeout: 60))

        lost.swipeLeft()
        app.buttons["Remove everywhere"].firstMatch.tap()
        app.buttons["Remove everywhere"].firstMatch.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: lost)
        wait(for: [gone], timeout: 30)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
    }
}
