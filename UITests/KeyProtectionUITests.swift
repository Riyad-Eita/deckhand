import UIKit
import XCTest

/// Face ID for server keys: turned on (one check), the saved password carries the access control after a relaunch
/// and the server connects after one check. Turned off again (one check), the item is plain again. Needs a server (TEST_RUNNER_DECKHAND_UPTIME_*) and an enrolled,
/// matching simulated face: run `xcrun simctl spawn <sim> notifyutil -p com.apple.BiometricKit_Sim.pearl.match`
/// in a loop while the test runs, skipped while `xcrun simctl pbpaste <sim>` is "deckhand-faceid-hold"
/// (DECKHAND_KEYPROTECTION_TEST=1).
final class KeyProtectionUITests: XCTestCase {
    func testProtectRelaunchUnlock() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_KEYPROTECTION_TEST"] == "1", let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else {
            throw XCTSkip("Needs a test server and a simulated face")
        }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_UPTIME_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_UPTIME_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SHOW_KEY_STATE"] = "1"
        app.launch()

        openSecurity(app)
        let toggle = app.switches["settings.keyProtection"]
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertEqual(app.staticTexts["settings.keyState"].label, "keys: plain")
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(waitFor(toggle, value: "1", timeout: 30), "Face ID check to turn it on")

        // A new launch starts locked: the home screen's check is cancelled (the face loop pauses while the pasteboard
        // says so). The item carries the access control; that a locked item can't be read only shows on a device —
        // the simulator's Keychain doesn't enforce it.
        app.terminate()
        UIPasteboard.general.string = "deckhand-faceid-hold"
        let relaunch = XCUIApplication()
        relaunch.launchEnvironment["DECKHAND_SHOW_KEY_STATE"] = "1"
        relaunch.launch()
        let cancel = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Cancel"]
        if cancel.waitForExistence(timeout: 8) { cancel.tap() }
        openSecurity(relaunch)
        XCTAssertEqual(relaunch.staticTexts["settings.keyState"].label, "keys: protected")
        UIPasteboard.general.string = ""
        let s = XCTAttachment(screenshot: relaunch.screenshot()); s.name = "locked"; s.lifetime = .keepAlways; add(s)
        relaunch.buttons["Done"].tap()

        // Opening the server asks once, then connects.
        let row = relaunch.staticTexts["sandbox"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(relaunch.otherElements["Connected"].waitForExistence(timeout: 40), "connected after the Face ID check")

        // Off again: the item is saved without the access control.
        relaunch.terminate()
        let last = XCUIApplication()
        last.launchEnvironment["DECKHAND_SHOW_KEY_STATE"] = "1"
        last.launch()
        openSecurity(last)
        let toggle2 = last.switches["settings.keyProtection"]
        XCTAssertEqual(toggle2.value as? String, "1")
        toggle2.switches.firstMatch.tap()
        XCTAssertTrue(waitFor(toggle2, value: "0", timeout: 30), "Face ID check to turn it off")
        last.terminate()
        let plain = XCUIApplication()
        plain.launchEnvironment["DECKHAND_SHOW_KEY_STATE"] = "1"
        plain.launch()
        openSecurity(plain)
        XCTAssertEqual(plain.staticTexts["settings.keyState"].label, "keys: plain")
    }

    private func openSecurity(_ app: XCUIApplication) {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let toggle = app.switches["settings.keyProtection"]
        var tries = 0
        while !(toggle.exists && toggle.isHittable) && tries < 10 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(app.staticTexts["settings.keyState"].waitForExistence(timeout: 5))
    }

    private func waitFor(_ e: XCUIElement, value: String, timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: e)], timeout: timeout) == .completed
    }
}
