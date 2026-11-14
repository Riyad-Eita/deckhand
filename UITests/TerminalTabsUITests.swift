import XCTest

/// Terminal tabs (TEST_RUNNER_DECKHAND_UPTIME_*, the server needs tmux): a second tab runs `top` and is named after
/// it, tabs survive a relaunch, and closing a tab ends its kept session (the harness checks `tmux ls`).
final class TerminalTabsUITests: XCTestCase {
    private func openTerminal(_ app: XCUIApplication) {
        let server = app.staticTexts["sandbox"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.tap()
        app.buttons["Terminal"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal.tab.1"].waitForExistence(timeout: 30))
    }

    func testTabs() throws {
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
        app.launch()
        openTerminal(app)

        app.buttons["terminal.tab.new"].tap()
        let second = app.descendants(matching: .any)["terminal.tab.2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(second.isSelected)
        sleep(4) // the shell attaches to its kept session
        app.typeText("top\n")
        // tmux names the tab after the running program.
        let named = NSPredicate(format: "label CONTAINS 'top'")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: named, object: second)], timeout: 20), .completed, second.label)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "two-tabs"; s.lifetime = .keepAlways; add(s)

        app.descendants(matching: .any)["terminal.tab.1"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal.tab.1"].isSelected)

        // Remembered after a relaunch.
        app.terminate()
        let again = XCUIApplication()
        again.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        again.launch()
        openTerminal(again)
        let tab2 = again.descendants(matching: .any)["terminal.tab.2"]
        XCTAssertTrue(tab2.waitForExistence(timeout: 10))
        tab2.tap()
        again.buttons["terminal.tab.close"].tap()
        XCTAssertTrue(tab2.waitForNonExistence(timeout: 5))
        sleep(3) // the server ends deckhand-2
    }
}
