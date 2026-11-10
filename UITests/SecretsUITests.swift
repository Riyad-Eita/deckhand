import XCTest

/// Secrets in a finished chat (seeded, made-up values): masked in the tool output and the reply, shown on tap.
/// Needs a server to open the chat on (TEST_RUNNER_DECKHAND_DEMO_*).
final class SecretsUITests: XCTestCase {
    func testSecretsAreMaskedUntilTapped() throws {
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
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "secrets|"
        app.launch()

        func text(_ s: String) -> XCUIElement { app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", s)).firstMatch }
        let reply = text("doesn't resolve")
        XCTAssertTrue(reply.waitForExistence(timeout: 30))
        XCTAssertFalse(reply.label.contains("ghp_"), "token visible in the reply")
        XCTAssertTrue(reply.label.contains("••••"))

        // The reply's own Show button.
        app.buttons["reply.secrets"].tap()
        XCTAssertTrue(text("ghp_").waitForExistence(timeout: 5))
        app.buttons["reply.secrets"].tap()

        // Open the tool card: output masked, then revealed.
        let card = app.buttons.containing(NSPredicate(format: "label CONTAINS 'cat .env'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        sleep(2)
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        let output = text("PORT=8080")
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        XCTAssertFalse(output.label.contains("S3cretDbPass"))
        XCTAssertFalse(output.label.contains("sk-proj-"))
        shot(app, "masked")
        let show = app.buttons["toolCard.secrets"]
        XCTAssertTrue(show.exists)
        show.tap()
        XCTAssertTrue(text("S3cretDbPass").waitForExistence(timeout: 5))
        shot(app, "revealed")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
}
