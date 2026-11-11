import XCTest

/// Disk usage on the demo server: drill into the home folder, find a big leftover folder (`old-build`, created
/// before the test) and delete it after confirming.
final class DiskUsageUITests: XCTestCase {
    func testFindAndDeleteLeftover() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_DEMO_HOST"], let password = env["DECKHAND_DEMO_PASSWORD"], let home = env["DECKHAND_DEMO_HOME"] else {
            throw XCTSkip("No demo server")
        }
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

        let row = app.buttons["dashboard.diskUsage"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 5 { app.swipeUp(); tries += 1 }
        row.tap()
        let homeEntry = app.buttons["disk.home"]
        XCTAssertTrue(homeEntry.waitForExistence(timeout: 60))
        XCTAssertFalse(home.isEmpty)
        sleep(1)
        let top = XCTAttachment(screenshot: app.screenshot()); top.name = "top"; top.lifetime = .keepAlways; add(top)
        homeEntry.tap()
        let leftover = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'old-build'")).firstMatch
        XCTAssertTrue(leftover.waitForExistence(timeout: 30))
        let folder = XCTAttachment(screenshot: app.screenshot()); folder.name = "folder"; folder.lifetime = .keepAlways; add(folder)
        leftover.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        app.buttons["Delete"].firstMatch.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: leftover)
        wait(for: [gone], timeout: 30)
    }
}
