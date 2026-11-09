import XCTest

/// Walks through the main flow against a real server. Credentials come from the environment:
/// TEST_RUNNER_DECKHAND_DEMO_HOST / _PORT / _USER / _PASSWORD (xcodebuild passes TEST_RUNNER_* through).
final class DemoFlowTests: XCTestCase {
    let env = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = false
    }

    func testAddServerTerminalToolsAndTask() throws {
        guard let host = env["DECKHAND_DEMO_HOST"], let password = env["DECKHAND_DEMO_PASSWORD"] else {
            throw XCTSkip("No demo server configured")
        }
        let app = XCUIApplication()
        app.launch()

        // Add the server
        app.buttons["Add Server"].firstMatch.tap()
        type(app.textFields["Host or IP"], host)
        type(app.textFields["User"], env["DECKHAND_DEMO_USER"] ?? "demo")
        let port = app.textFields["Port"]
        port.tap()
        port.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        port.typeText(env["DECKHAND_DEMO_PORT"] ?? "22")
        type(app.textFields["Name (optional)"], "Demo server")
        app.buttons["Password"].tap()
        type(app.secureTextFields["Password"], password)
        pause(1)

        // Test the connection and trust the host key
        app.buttons["Test Connection"].tap()
        let trust = app.alerts.buttons["Trust"]
        XCTAssertTrue(trust.waitForExistence(timeout: 30))
        pause(2)
        trust.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Linux'")).firstMatch.waitForExistence(timeout: 30))
        pause(2)
        app.buttons["Save"].tap()
        if app.buttons["Not Now"].waitForExistence(timeout: 12) { app.buttons["Not Now"].tap(); pause(1) }
        XCTAssertTrue(app.staticTexts["Demo server"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(identifier: "Demo server").count, 1, "Server must be saved once")
        pause(1)

        // Open the server, use the terminal
        app.cells.containing(.staticText, identifier: "Demo server").firstMatch.tap()
        tapSegment(app, "Terminal")
        pause(4)
        app.typeText("ls projects && cat projects/weather-api/logs/app.log\n")
        pause(4)

        // Server tools
        app.buttons["Server Tools"].tap()
        XCTAssertTrue(app.staticTexts["Coding agents"].waitForExistence(timeout: 20))
        pause(3)
        app.buttons["Done"].tap()

        // Start a task in a folder
        tapSegment(app, "Agent")
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Your model key'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["projects"].waitForExistence(timeout: 20))
        pause(1)
        app.buttons["projects"].tap()
        XCTAssertTrue(app.buttons["weather-api"].waitForExistence(timeout: 20))
        app.buttons["weather-api"].tap()
        pause(2)
        app.buttons["Use Folder"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'weather-api'")).firstMatch.waitForExistence(timeout: 10))
        pause(3)

        // Settings → Connections
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Settings"].tap()
        pause(2)
        app.swipeUp()
        app.buttons["Connections"].tap()
        XCTAssertTrue(app.staticTexts["DeepWiki"].waitForExistence(timeout: 10))
        pause(3)
    }

    private func tapSegment(_ app: XCUIApplication, _ name: String) {
        let candidates = [app.segmentedControls.buttons[name], app.buttons[name], app.staticTexts[name]]
        for c in candidates where c.waitForExistence(timeout: 3) {
            c.tap()
            return
        }
        XCTFail("No segment \(name):\n\(app.debugDescription)")
    }

    private func type(_ field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text)
    }

    private func pause(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
