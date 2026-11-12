import XCTest

/// One-tap app installs on a server with Docker (TEST_RUNNER_DECKHAND_DASH_*): the catalog, Redis installed under a
/// throwaway name with its credentials shown, then removed with its data.
final class AppInstallsUITests: XCTestCase {
    func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }

    func testInstallAndRemoveRedis() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_DASH_HOST"], let key = env["DECKHAND_DASH_KEY"] else { throw XCTSkip("No server configured") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_DASH_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_DASH_USER"] ?? "root"
        app.launchEnvironment["DECKHAND_SEED_KEY"] = key
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "web-1"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()

        let row = app.buttons["dashboard.apps"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var t = 0
        while !row.isHittable && t < 8 { app.swipeUp(); t += 1 }
        row.tap()
        let redis = app.buttons["apps.template.redis"]
        XCTAssertTrue(redis.waitForExistence(timeout: 20))
        shot(app, "catalog")
        redis.tap()

        let name = "dh-ui-redis-\(Int(Date().timeIntervalSince1970) % 100000)"
        let field = app.textFields["apps.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText(name + "\n")
        app.buttons["apps.install"].tap()
        XCTAssertTrue(app.staticTexts["apps.installed"].waitForExistence(timeout: 600) || app.descendants(matching: .any)["apps.installed"].exists)
        XCTAssertTrue(app.buttons["apps.credential.Connection"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["apps.credential.Password"].exists)
        shot(app, "installed")
        app.buttons["apps.done"].tap()

        let installed = app.buttons["apps.installed.\(name)"]
        XCTAssertTrue(installed.waitForExistence(timeout: 30))
        installed.tap()
        XCTAssertTrue(app.buttons["apps.credential.Connection"].waitForExistence(timeout: 20))
        shot(app, "app")
        let remove = app.buttons["apps.remove"]
        t = 0
        while !remove.isHittable && t < 6 { app.swipeUp(); t += 1 }
        remove.tap()
        app.buttons["Remove with all its data"].tap()
        XCTAssertTrue(redis.waitForExistence(timeout: 120))
        XCTAssertTrue(installed.waitForNonExistence(timeout: 30))
    }
}
