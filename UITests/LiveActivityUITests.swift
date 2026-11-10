import XCTest

/// Live Activity: a Codex task on a server (DECKHAND_WEB_HOST/PORT/USER/KEY, Codex signed in there) shows in the
/// Dynamic Island while it runs.
final class LiveActivityUITests: XCTestCase {
    func testTaskShowsInDynamicIsland() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_WEB_HOST"], let key = env["DECKHAND_WEB_KEY"] else { throw XCTSkip("No server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_WEB_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_WEB_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_KEY"] = key
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "web-1"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "codex|Run this exact shell command and wait for it: sleep 40. Then reply with just: done"
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 20) { allow.tap() }
        sleep(12)
        shot("app")
        XCUIDevice.shared.press(.home)
        sleep(3)
        shot("island")
        // Long-press the island for the expanded view.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.025)).press(forDuration: 1.2)
        sleep(2)
        shot("expanded")
        coverSheet(springboard, "lockscreen")
        app.activate()
        XCTAssertTrue(app.staticTexts["done"].waitForExistence(timeout: 120))
        XCUIDevice.shared.press(.home)
        sleep(8)
        shot("ended")
        coverSheet(springboard, "lockscreen-ended")
    }

    /// Locks the simulator to show the Lock Screen presentation, then unlocks it again (no passcode).
    private func coverSheet(_ springboard: XCUIApplication, _ name: String) {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(2)
        shot(name)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        sleep(2)
    }

    private func shot(_ name: String) {
        let s = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
}
