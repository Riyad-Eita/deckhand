import XCTest

/// App lock: with the lock on, the app starts on the lock screen and the server list can't be reached.
/// Unlocking needs a (simulated) face: `xcrun simctl spawn <sim> notifyutil -p com.apple.BiometricKit_Sim.pearl.match`.
final class AppLockUITests: XCTestCase {
    func testStartsLocked() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_APPLOCK"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = "example.com"
        app.launchEnvironment["DECKHAND_SEED_USER"] = "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = "unused"
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "locked-server"
        app.launch()

        XCTAssertTrue(app.staticTexts["Deckhand is locked"].waitForExistence(timeout: 10))
        // Dismiss the system Face ID sheet, the lock screen stays.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cancel = springboard.buttons["Cancel"]
        if cancel.waitForExistence(timeout: 5) { cancel.tap() }
        let unlock = app.buttons["appLock.unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["locked-server"].isHittable)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "locked"; s.lifetime = .keepAlways; add(s)
    }
}
