import XCTest

/// Secure a fresh server: on a disposable server with root password login (DECKHAND_PROV_*), the app creates an
/// admin user with its key, switches to it, turns root and password logins off and sets up the extras.
final class ProvisionUITests: XCTestCase {
    func testProvisionFreshServer() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_PROV_HOST"], let password = env["DECKHAND_PROV_ROOT_PASSWORD"] else { throw XCTSkip("No fresh test server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_PROV_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = "root"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "new-vps"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()

        let row = app.buttons["dashboard.provision"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 5 { app.swipeUp(); tries += 1 }
        row.tap()
        XCTAssertTrue(app.textFields["provision.username"].waitForExistence(timeout: 30))
        sleep(1)
        shot(app, "plan")
        let start = app.buttons["provision.start"]
        tries = 0
        while !(start.exists && start.isHittable) && tries < 6 { app.swipeUp(); tries += 1 }
        shot(app, "plan-steps")
        start.tap()
        app.buttons["Set up"].tap()
        let done = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Your server is set up'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 400))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'deploy · key'")).firstMatch.exists)
        shot(app, "progress")
        app.swipeUp()
        shot(app, "report")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
}
