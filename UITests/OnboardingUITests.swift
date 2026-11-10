import XCTest

/// First launch: welcome → add a server (password swapped for a key) → pick an agent.
final class OnboardingUITests: XCTestCase {
    func testOnboardingAddsServerAndOffersEngines() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_DEMO_HOST"], let password = env["DECKHAND_DEMO_PASSWORD"] else { throw XCTSkip("No demo server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_ONBOARDING"] = "1"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Your servers, in your pocket"].waitForExistence(timeout: 10))
        attach(app, "1-welcome")
        app.buttons["Get Started"].tap()
        XCTAssertTrue(app.staticTexts["Add your server"].waitForExistence(timeout: 5))
        attach(app, "2-server")
        app.buttons["onboarding.addServer"].tap()
        type(app.textFields["Host or IP"], host)
        type(app.textFields["User"], env["DECKHAND_DEMO_USER"] ?? "demo")
        let port = app.textFields["Port"]
        port.tap(); port.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        port.typeText(env["DECKHAND_DEMO_PORT"] ?? "22")
        type(app.textFields["Name (optional)"], "Demo server")
        app.buttons["Password"].tap()
        type(app.secureTextFields["Password"], password)
        app.buttons["Test Connection"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Secure key installed'")).firstMatch.waitForExistence(timeout: 60))
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Pick your agent"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Claude Code'")).firstMatch.exists)
        attach(app, "3-engine")
        app.buttons["Later"].tap()
        XCTAssertTrue(app.staticTexts["Demo server"].waitForExistence(timeout: 10))
    }

    private func type(_ field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText(text)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
