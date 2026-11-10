import XCTest

/// Change history: open a past security change, enter the sudo password, see the diff, roll it back.
/// Needs a disposable server whose user has a sudo password (DECKHAND_SUDO_*) and a seeded history.
final class ChangesUITests: XCTestCase {
    func testDiffNeedsSudoPasswordThenRollBack() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_SUDO_HOST"], let password = env["DECKHAND_SUDO_PASSWORD"] else { throw XCTSkip("No sudo test server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_SUDO_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_SUDO_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "web-1"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()

        let row = app.buttons["dashboard.changes"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.swipeUpIfNeeded(in: app)
        row.tap()
        let change = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Turn off password logins'")).firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 20))
        shot(app, "history")
        change.tap()
        app.buttons["Show the difference to now"].tap()
        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.typeText(password)
        app.alerts.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["+PasswordAuthentication no"].waitForExistence(timeout: 20))
        shot(app, "diff")

        app.buttons["Roll back"].tap()
        app.buttons["rootTask.confirm"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 30))
        shot(app, "rollback")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
}

private extension XCUIElement {
    func swipeUpIfNeeded(in app: XCUIApplication) {
        var tries = 0
        while !isHittable && tries < 4 { app.swipeUp(); tries += 1 }
    }
}
