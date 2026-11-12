import XCTest

/// A long task whose first steps were summarized: the chat marks the spot and shows the summary on tap
/// (seeded, no model call). Needs a server to open (TEST_RUNNER_DECKHAND_DEMO_*).
final class CompactionUITests: XCTestCase {
    func testSummaryDivider() throws {
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
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "compacted|"
        app.launch()

        func text(_ s: String) -> XCUIElement { app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", s)).firstMatch }
        let divider = app.buttons["chat.summary"]
        XCTAssertTrue(divider.waitForExistence(timeout: 60))
        // The earlier steps stay visible above the divider.
        XCTAssertTrue(text("Upgrade the shop to Node 22").exists)
        XCTAssertLessThan(text("Installed Node 22 and rebuilt").frame.minY, divider.frame.minY)
        XCTAssertGreaterThan(text("Restart it.").frame.minY, divider.frame.minY)
        XCTAssertFalse(text("Open: restart the service").exists)
        divider.tap()
        XCTAssertTrue(text("Open: restart the service").waitForExistence(timeout: 5))
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "summary"; s.lifetime = .keepAlways; add(s)
    }
}
