import XCTest

/// Deleting a server always asks first: a full swipe doesn't delete, and Cancel keeps the server.
final class ServerDeleteUITests: XCTestCase {
    func testDeleteAsksFirst() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_EXTRA"] = "keep-me|keep.example.com|me"
        app.launch()
        let row = app.staticTexts["keep-me"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))

        // A long, fast swipe used to delete right away.
        row.swipeLeft(velocity: .fast)
        sleep(1)
        XCTAssertTrue(row.exists, "a full swipe must not delete")
        let delete = app.buttons["Delete"]
        if !delete.exists { row.swipeLeft() }
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["server.delete.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "confirm"; s.lifetime = .keepAlways; add(s)
        app.buttons["Cancel"].firstMatch.exists ? app.buttons["Cancel"].firstMatch.tap() : app.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Cancel keeps the server")

        row.swipeLeft()
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10))
    }
}
