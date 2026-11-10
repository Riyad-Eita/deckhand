import XCTest

/// A finished reply with every Markdown block (seeded, no server run needed): heading, inline code, highlighted
/// code block, table, numbered and bullet lists, quote. Needs a server to open (TEST_RUNNER_DECKHAND_DEMO_*).
final class MarkdownUITests: XCTestCase {
    func testReplyRendersAllBlocks() throws {
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
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "markdown|"
        app.launch()

        func text(_ s: String) -> XCUIElement { app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", s)).firstMatch }
        XCTAssertTrue(text("What happens").waitForExistence(timeout: 30))
        XCTAssertTrue(text("def do_GET").exists, "code block")
        XCTAssertTrue(text("berlin").exists, "table")
        XCTAssertTrue(text("Add the missing cities").exists, "numbered list")
        XCTAssertTrue(text("systemctl restart").exists, "bullet list")
        XCTAssertTrue(text("Nothing was changed yet").exists, "quote")
        // The table fits the screen (three columns wrap instead of scrolling).
        let cell = text("paris")
        XCTAssertTrue(cell.exists)
        XCTAssertLessThanOrEqual(cell.frame.maxX, app.frame.maxX)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "reply"; s.lifetime = .keepAlways; add(s)
    }
}
