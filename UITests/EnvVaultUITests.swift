import XCTest

/// Environment files on the disposable server (TEST_RUNNER_DECKHAND_UPTIME_*, DECKHAND_VAULT_TEST=1): a new .env in
/// ~/dh-vault-ui, a variable whose value stays masked, written to the server, then shown as in sync.
final class EnvVaultUITests: XCTestCase {
    func testAddVariableAndWrite() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_VAULT_TEST"] == "1", let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else { throw XCTSkip("No test server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_UPTIME_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_UPTIME_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()
        let row = app.buttons["dashboard.vault"]
        XCTAssertTrue(row.waitForExistence(timeout: 40))
        var t = 0
        while !row.isHittable && t < 10 { app.swipeUp(); t += 1 }
        row.tap()

        let path = app.textFields["vault.path"]
        XCTAssertTrue(path.waitForExistence(timeout: 20))
        path.tap(); path.typeText("~/dh-vault-ui/.env")
        app.buttons["vault.add"].tap()
        let file = app.buttons["vault.file.~/dh-vault-ui/.env"]
        XCTAssertTrue(file.waitForExistence(timeout: 20))
        file.tap()
        let key = app.textFields["vault.newKey"]
        XCTAssertTrue(key.waitForExistence(timeout: 10))
        key.tap(); key.typeText("API_KEY")
        let value = app.secureTextFields["vault.newValue"]
        value.tap(); value.typeText("abc123secret")
        app.buttons["vault.addVar"].tap()
        XCTAssertTrue(app.staticTexts["API_KEY"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["abc123secret"].exists, "value should be masked")
        app.buttons["vault.write"].tap()
        app.buttons["Write"].tap()
        XCTAssertTrue(app.staticTexts["Written as 0600."].waitForExistence(timeout: 30))
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "vault"; s.lifetime = .keepAlways; add(s)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'in sync'")).firstMatch.waitForExistence(timeout: 20))
    }
}
