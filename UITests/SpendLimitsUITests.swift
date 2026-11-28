import XCTest

/// Spending limits for the own key: switched on in Settings, with an amount and today's spend.
final class SpendLimitsUITests: XCTestCase {
    func testLimitsInSettings() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launch()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let task = app.switches["settings.limit.task"]
        var t = 0
        while !(task.exists && task.isHittable) && t < 10 { app.swipeUp(); t += 1 }
        XCTAssertTrue(task.exists)
        XCTAssertEqual(task.value as? String, "0")
        task.switches.firstMatch.tap()
        XCTAssertEqual(task.value as? String, "1")
        let amount = app.steppers["settings.limit.task.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.buttons["settings.limit.task.amount-Increment"].tap()
        XCTAssertTrue(app.staticTexts["$1.25"].exists)
        XCTAssertTrue(app.staticTexts["settings.spentToday"].exists || app.otherElements["settings.spentToday"].exists || app.staticTexts["Spent today"].exists)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "limits"; s.lifetime = .keepAlways; add(s)
    }
}
