import XCTest

/// SSH port: move SSH to a new port on a disposable systemd server (DECKHAND_PORT_*); the app proves logins
/// on the new port before the old one closes and saves the new port.
final class SSHPortUITests: XCTestCase {
    func testMoveSSHPort() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_PORT_HOST"], let password = env["DECKHAND_PORT_PASSWORD"], let newPort = env["DECKHAND_PORT_NEW"] else {
            throw XCTSkip("No port test server")
        }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_PORT_OLD"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_PORT_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "web-1"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()

        let row = app.buttons["dashboard.sshPort"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 4 { app.swipeUp(); tries += 1 }
        row.tap()
        let pw = app.secureTextFields.firstMatch
        XCTAssertTrue(pw.waitForExistence(timeout: 15))
        pw.typeText(password)
        app.alerts.buttons["Continue"].tap()

        let field = app.textFields["sshPort.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText(newPort)
        shot(app, "before")
        app.buttons["sshPort.start"].tap()
        let move = app.buttons["Move SSH"]
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        move.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'SSH now runs on port \(newPort)'")).firstMatch.waitForExistence(timeout: 180))
        shot(app, "moved")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
}
