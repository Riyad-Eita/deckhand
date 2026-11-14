import XCTest

/// A `deckhand://add` link (as from a scanned QR code) opens the import screen on a fresh install; nothing is added
/// until Import. The new server can then be shared back as a link and QR code.
final class ServerLinkUITests: XCTestCase {
    func testImportFromLinkAndShare() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_SKIPAUTH"] = "1"
        app.launchEnvironment["DECKHAND_SEED_OPEN_URL"] = "deckhand://add?host=203.0.113.10&user=deploy&port=2222&name=Web%20box"
        if let look = ProcessInfo.processInfo.environment["DECKHAND_APPEARANCE"] { app.launchEnvironment["DECKHAND_APPEARANCE"] = look }
        app.launch()

        XCTAssertTrue(app.staticTexts["import.fromLink"].waitForExistence(timeout: 20) || app.otherElements["import.fromLink"].exists)
        let row = app.buttons["import.host.Web box"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["deploy@203.0.113.10:2222"].exists)
        shot(app, "link")

        app.buttons["import.go"].tap()
        // No password or key came with the link: the screen says so and stays until Done.
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()

        let server = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Web box,'")).firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 15))
        shot(app, "home")
        server.swipeRight()
        let share = app.buttons["Share"].firstMatch
        if !share.waitForExistence(timeout: 5) {
            shot(app, "swiped")
            XCTFail(app.debugDescription)
        }
        share.tap()

        let link = app.staticTexts["share.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        XCTAssertTrue(link.label.contains("host=203.0.113.10"), link.label)
        XCTAssertTrue(link.label.contains("port=2222"), link.label)
        XCTAssertFalse(link.label.lowercased().contains("password"))
        XCTAssertTrue(app.images["share.qr"].exists)
        shot(app, "share")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
