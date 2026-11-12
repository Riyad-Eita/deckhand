import XCTest

/// "Plan first": a seeded plan reply shows as a checklist with a plan bar; a step can be left out, Adjust fills the
/// composer, Run sends only the chosen steps. Needs a server to open (TEST_RUNNER_DECKHAND_UPTIME_*); the run itself
/// goes to Codex on that server, which may not be installed — only the sent message is checked.
final class PlanModeUITests: XCTestCase {
    func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }

    func launch(_ style: String = "light") throws -> XCUIApplication {
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
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "plan|"
        app.launchEnvironment["DECKHAND_APPEARANCE"] = style
        app.launch()
        return app
    }

    func testPlanRunAdjustCancel() throws {
        let app = try launch()
        XCTAssertTrue(app.descendants(matching: .any)["chat.plan"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Change the upstream port from 8080 to 8081"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Plan first]'")).firstMatch.exists, "plan instructions shown")
        XCTAssertTrue(app.descendants(matching: .any)["chat.planFirst"].exists)
        shot(app, "plan")

        // Adjust fills the composer and closes the bar.
        app.buttons["plan.adjust"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5) || app.textFields.firstMatch.exists)
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertEqual(field.value as? String, "Change the plan: ")
        XCTAssertFalse(app.buttons["plan.run"].exists)
        app.terminate()

        // Run without step 3.
        let again = try launch()
        let step = again.buttons["plan.step.2"]
        XCTAssertTrue(step.waitForExistence(timeout: 30))
        step.tap()
        shot(again, "skipped")
        again.buttons["plan.run"].tap()
        let sent = again.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Go ahead with the plan'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10))
        XCTAssertTrue(sent.label.contains("3. Test with nginx -t") && !sent.label.contains("Restart the shop service"), sent.label)
        again.terminate()

        // Dark mode, then Cancel.
        let dark = try launch("dark")
        XCTAssertTrue(dark.buttons["plan.cancel"].waitForExistence(timeout: 30))
        shot(dark, "plan-dark")
        dark.buttons["plan.cancel"].tap()
        XCTAssertFalse(dark.buttons["plan.run"].waitForExistence(timeout: 2))
    }
}
