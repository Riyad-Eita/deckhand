import XCTest

/// Crash reports: a seeded MetricKit payload (a crash and a hang) is listed in Settings, the crash explained with its
/// frames, and can be shared or reported — nothing is sent by itself.
final class CrashReportsUITests: XCTestCase {
    func testListAndDetail() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_DIAGNOSTIC"] = "1"
        app.launch()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let row = app.buttons["settings.crashReports"]
        var t = 0
        while !(row.exists && row.isHittable) && t < 10 { app.swipeUp(); t += 1 }
        row.tap()

        let crash = app.buttons["crash.report.crash"]
        XCTAssertTrue(crash.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["crash.report.hang"].exists)
        let l = XCTAttachment(screenshot: app.screenshot()); l.name = "list"; l.lifetime = .keepAlways; add(l)
        crash.tap()
        XCTAssertTrue(app.staticTexts["crash.headline"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["crash.headline"].label, "EXC_BREAKPOINT (SIGTRAP)")
        XCTAssertTrue(app.staticTexts["0  Deckhand + 123456"].exists)
        XCTAssertTrue(app.buttons["crash.github"].exists)
        let d = XCTAttachment(screenshot: app.screenshot()); d.name = "detail"; d.lifetime = .keepAlways; add(d)
    }
}
