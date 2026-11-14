import XCTest

/// Hardware keyboard in the terminal (TEST_RUNNER_DECKHAND_UPTIME_*, DECKHAND_HW_KEYBOARD_TEST=1): Cmd+T/1/Shift+]/W
/// for tabs, Cmd+= for text size, and Ctrl+C reaches the server — `sleep 5 && touch /tmp/dh-ctrlc` is interrupted, so
/// the harness finds no file. Needs a simulator with a connected hardware keyboard (shown in the Simulator app);
/// headless simulators don't turn XCUITest's typeKey into key presses.
final class TerminalShortcutsUITests: XCTestCase {
    private func size(_ app: XCUIApplication) -> Int {
        app.buttons["terminal.appearance"].tap()
        let header = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Text size'")).firstMatch
        _ = header.waitForExistence(timeout: 5)
        let n = Int(header.label.split(separator: " ").last ?? "") ?? 0
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.95)).tap()
        return n
    }

    func testShortcuts() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_HW_KEYBOARD_TEST"] == "1", let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else {
            throw XCTSkip("Needs a test server and a simulator with a hardware keyboard")
        }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_UPTIME_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_UPTIME_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launch()
        let server = app.staticTexts["sandbox"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.tap()
        app.buttons["Terminal"].tap()
        let tab1 = app.descendants(matching: .any)["terminal.tab.1"], tab2 = app.descendants(matching: .any)["terminal.tab.2"]
        XCTAssertTrue(tab1.waitForExistence(timeout: 30))
        sleep(4)

        // Ctrl+C interrupts the command on the server.
        app.typeText("sleep 5 && touch /tmp/dh-ctrlc\n")
        sleep(1)
        app.typeKey("c", modifierFlags: .control)
        sleep(6)

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(tab2.waitForExistence(timeout: 5))
        XCTAssertTrue(tab2.isSelected)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(tab1.isSelected)
        app.typeKey("]", modifierFlags: [.command, .shift])
        XCTAssertTrue(tab2.isSelected)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(tab2.waitForNonExistence(timeout: 5))

        let before = size(app)
        app.typeKey("=", modifierFlags: .command)
        XCTAssertEqual(size(app), before + 1)
        app.typeKey("0", modifierFlags: .command)
        XCTAssertEqual(size(app), 13)
    }
}
