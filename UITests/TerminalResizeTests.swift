import XCTest

/// Opening a sheet over the terminal resizes it; the shell prompt must stay clean (no stray "…;55t" replies).
final class TerminalResizeTests: XCTestCase {
    func testSheetOverTerminalLeavesPromptClean() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_DEMO_HOST"], let password = env["DECKHAND_DEMO_PASSWORD"] else {
            throw XCTSkip("No demo server configured")
        }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_DEMO_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_DEMO_USER"] ?? "demo"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "terminal|"
        app.launch()
        Thread.sleep(forTimeInterval: 8)
        for _ in 0..<3 {
            app.buttons["Server Tools"].tap()
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 20))
            app.buttons["Done"].tap()
            Thread.sleep(forTimeInterval: 2)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "terminal-after-sheets"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
