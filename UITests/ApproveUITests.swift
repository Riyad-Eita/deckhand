import XCTest

/// A risky command waits on a server for a lock-screen answer; the app opens from the push link and allows it.
/// The server side (hook waiting on ntfy) is started by the test script before this runs.
final class ApproveUITests: XCTestCase {
    func testAllowFromLink() throws {
        let env = ProcessInfo.processInfo.environment
        guard let topic = env["DECKHAND_APPROVE_TOPIC"], let link = env["DECKHAND_APPROVE_LINK"] else { throw XCTSkip("No approval waiting") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_NTFY"] = topic
        app.launchEnvironment["DECKHAND_SEED_OPEN_URL"] = link
        app.launchEnvironment["DECKHAND_SEED_SKIPAUTH"] = "1"
        app.launch()
        let allow = app.buttons["approve.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 30))
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "ask"; a.lifetime = .keepAlways; add(a)
        allow.tap()
        XCTAssertTrue(app.staticTexts["Allowed. The agent continues."].waitForExistence(timeout: 30))
    }
}
