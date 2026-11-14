import XCTest

/// Terminal look (TEST_RUNNER_DECKHAND_UPTIME_*): pick a light color scheme, pinch to zoom, and both are kept after a
/// relaunch.
final class TerminalAppearanceUITests: XCTestCase {
    private func openTerminal(_ app: XCUIApplication) {
        let server = app.staticTexts["sandbox"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.tap()
        app.buttons["Terminal"].tap()
        XCTAssertTrue(app.buttons["terminal.appearance"].waitForExistence(timeout: 30))
    }

    private func textSize(_ app: XCUIApplication) -> Int {
        app.buttons["terminal.appearance"].tap()
        let header = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Text size'")).firstMatch
        _ = header.waitForExistence(timeout: 5)
        let n = Int(header.label.split(separator: " ").last ?? "") ?? 0
        closeMenu(app)
        return n
    }

    func testThemeAndZoomAreKept() throws {
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
        app.launchEnvironment["DECKHAND_SEED_NOKEYBOARD"] = "1"
        app.launch()
        openTerminal(app)

        let before = textSize(app)
        app.buttons["terminal.appearance"].tap()
        app.buttons["Paper"].tap()
        sleep(1)
        let terminal = app.descendants(matching: .any)["terminal.view"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        terminal.pinch(withScale: 1.8, velocity: 1)
        sleep(1)
        let after = textSize(app)
        XCTAssertGreaterThan(after, before)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "paper"; s.lifetime = .keepAlways; add(s)

        // Remembered: a new launch (without reset) shows the same.
        app.terminate()
        let again = XCUIApplication()
        again.launchEnvironment["DECKHAND_SEED_NOKEYBOARD"] = "1"
        again.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        again.launch()
        openTerminal(again)
        XCTAssertEqual(textSize(again), after)
        again.buttons["terminal.appearance"].tap()
        XCTAssertTrue(again.buttons["Paper"].isSelected || again.buttons["Paper"].value as? String == "1")
        closeMenu(again)
    }

    /// Taps outside the menu (bottom left, in the terminal) — the middle of the screen would hit a menu item.
    private func closeMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.95)).tap()
    }
}
