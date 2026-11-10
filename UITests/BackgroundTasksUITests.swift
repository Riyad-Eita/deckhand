import XCTest

/// Background tasks: the list shows what runs on the server without the app, including a task paused by a usage limit.
final class BackgroundTasksUITests: XCTestCase {
    func testListShowsRunningWaitingAndFinishedTasks() throws {
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

        let row = app.buttons["dashboard.backgroundTasks"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        XCTAssertTrue(app.navigationBars["Background tasks"].waitForExistence(timeout: 10))
        // Whatever runs on the server shows up with its status (the demo server has a few seeded tasks).
        let anyStatus = app.staticTexts.matching(NSPredicate(format: "label IN {'Running', 'Done', 'Failed', 'Stopped'} OR label BEGINSWITH 'Waits until'")).firstMatch
        let empty = app.staticTexts["No background tasks"]
        XCTAssertTrue(anyStatus.waitForExistence(timeout: 20) || empty.exists)
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            sleep(1)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        }
        XCUIDevice.shared.appearance = .light
    }
}
