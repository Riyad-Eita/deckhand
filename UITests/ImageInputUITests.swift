import XCTest

/// Pictures for the own-key agent: a seeded screenshot waits in the composer, is sent with the message and shows in
/// the bubble. The key is deliberately invalid, so the provider's error is shown instead of a reply.
/// Needs a server to open (TEST_RUNNER_DECKHAND_UPTIME_*).
final class ImageInputUITests: XCTestCase {
    func testPictureGoesWithTheMessage() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else { throw XCTSkip("No test server") }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_UPTIME_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_UPTIME_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_APIKEY"] = "invalid-test-key"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "ownKey|"
        app.launchEnvironment["DECKHAND_SEED_IMAGE"] = "1"
        app.launch()

        let pending = app.scrollViews["chat.images"]
        XCTAssertTrue(pending.waitForExistence(timeout: 30))
        let s1 = XCTAttachment(screenshot: app.screenshot()); s1.name = "pending"; s1.lifetime = .keepAlways; add(s1)
        app.buttons["Send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.sentImages"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["What do you see here?"].exists)
        XCTAssertFalse(pending.exists)
        // The invalid key comes back as an error, not a crash or a hang.
        XCTAssertTrue(app.buttons["Stop"].waitForNonExistence(timeout: 60), "still running")
        let problem = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '401' OR label CONTAINS[c] 'invalid' OR label CONTAINS[c] 'authentication'")).firstMatch
        XCTAssertTrue(problem.waitForExistence(timeout: 10), "no error shown")
        let s2 = XCTAttachment(screenshot: app.screenshot()); s2.name = "sent"; s2.lifetime = .keepAlways; add(s2)
    }
}
