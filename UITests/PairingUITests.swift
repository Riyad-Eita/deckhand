import XCTest

/// Pairing by QR code, end to end against the disposable server: a code made there by `scripts/pair.sh`
/// (TEST_RUNNER_DECKHAND_PAIR_LINK) is opened like the Camera app would, one tap on Connect, and the new server
/// opens signed in with a key made in the app.
final class PairingUITests: XCTestCase {
    func testPairFromALink() throws {
        guard let link = ProcessInfo.processInfo.environment["DECKHAND_PAIR_LINK"], let url = URL(string: link) else { throw XCTSkip("No pairing code") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launch()
        // The empty home screen offers pairing first.
        let pair = app.buttons["home.pair"]
        XCTAssertTrue(pair.waitForExistence(timeout: 15))
        pair.tap()
        XCTAssertTrue(app.buttons["pair.copy"].waitForExistence(timeout: 5))
        let guide = XCTAttachment(screenshot: app.screenshot()); guide.name = "guide"; guide.lifetime = .keepAlways; add(guide)
        app.buttons["Cancel"].firstMatch.tap()

        app.open(url)
        let connect = app.buttons["pair.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "sandbox")).firstMatch.exists)
        let confirm = XCTAttachment(screenshot: app.screenshot()); confirm.name = "confirm"; confirm.lifetime = .keepAlways; add(confirm)
        connect.tap()
        XCTAssertTrue(connect.waitForNonExistence(timeout: 30), "the sheet closes after pairing")
        XCTAssertTrue(app.staticTexts["sandbox"].waitForExistence(timeout: 15))
        let done = XCTAttachment(screenshot: app.screenshot()); done.name = "paired"; done.lifetime = .keepAlways; add(done)
    }
}
