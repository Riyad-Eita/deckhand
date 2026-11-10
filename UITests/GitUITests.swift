import XCTest

/// Git: open the demo repository, look at a diff, stage, commit. The demo server's weather-api repository needs
/// an uncommitted change to README.md before the test (and a reset afterwards).
final class GitUITests: XCTestCase {
    func testDiffStageAndCommit() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_DEMO_HOST"], let password = env["DECKHAND_DEMO_PASSWORD"] else { throw XCTSkip("No demo server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_DEMO_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_DEMO_USER"] ?? "demo"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()

        let row = app.buttons["dashboard.git"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 4 { app.swipeUp(); tries += 1 }
        row.tap()
        let repo = app.buttons.containing(NSPredicate(format: "label CONTAINS 'weather-api'")).firstMatch
        XCTAssertTrue(repo.waitForExistence(timeout: 40))
        repo.tap()
        let file = app.buttons.containing(NSPredicate(format: "label CONTAINS 'README.md'")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30))
        shot(app, "status")
        file.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '+'")).firstMatch.waitForExistence(timeout: 20))
        shot(app, "diff")
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["Stage all"].tap()
        let message = app.textFields["git.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 20))
        message.tap()
        message.typeText("Document the rate limit")
        app.buttons["git.commit"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'working tree is clean'")).firstMatch.waitForExistence(timeout: 30))
        shot(app, "committed")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
}
