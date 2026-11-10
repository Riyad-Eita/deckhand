import XCTest

/// Docker: list containers, restart the demo container (the only container this test touches), see compose stacks.
final class DockerUITests: XCTestCase {
    func testContainersRestartAndCompose() throws {
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

        let docker = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Docker'")).firstMatch
        XCTAssertTrue(docker.waitForExistence(timeout: 30))
        docker.tap()
        let demo = app.buttons.containing(NSPredicate(format: "label CONTAINS 'deckhand-demo'")).firstMatch
        XCTAssertTrue(demo.waitForExistence(timeout: 40))
        demo.tap()
        let restart = app.buttons["Restart"]
        XCTAssertTrue(restart.waitForExistence(timeout: 10))
        restart.tap()
        let confirm = app.buttons.matching(identifier: "Restart").element(boundBy: 1)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Restart done."].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'second'")).firstMatch.waitForExistence(timeout: 20), "status refreshed after restart")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.buttons["Pull images"].firstMatch.waitForExistence(timeout: 10))
    }
}
