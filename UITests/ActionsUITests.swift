import XCTest

/// GitHub Actions (seeded `gh` output, no server or GitHub needed): runs of a repository and a failed run's digest.
final class ActionsUITests: XCTestCase {
    func testRunsAndAFailedRun() throws {
        let runs = #"[{"conclusion":"","createdAt":"2026-11-28T14:20:25Z","databaseId":11,"displayTitle":"Cache the session lookup","event":"pull_request","headBranch":"session-cache","status":"in_progress","url":"https://github.com/acme/web/actions/runs/11","workflowName":"CI"},{"conclusion":"failure","createdAt":"2026-11-28T12:00:00Z","databaseId":10,"displayTitle":"Bump Go to 1.27","event":"push","headBranch":"main","status":"completed","url":"https://github.com/acme/web/actions/runs/10","workflowName":"CI"}]"#
        let detail = #"{"jobs":[{"name":"test","status":"completed","conclusion":"failure","steps":[{"name":"Checkout","status":"completed","conclusion":"success"},{"name":"go test ./...","status":"completed","conclusion":"failure"}]}]}"#
            + "|@@log|test~go test ./...~2026-11-28T12:01:00Z --- FAIL: TestSessionExpiry (0.02s)|test~go test ./...~2026-11-28T12:01:00Z     session_test.go:41: expected expiry after 5m, got 0s|test~go test ./...~2026-11-28T12:01:01Z FAIL github.com/acme/web 0.412s"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "DECKHAND_RESET": "1", "DECKHAND_SEED_SKIPAUTH": "1", "DECKHAND_SEED_TRUST": "1",
            "DECKHAND_SEED_HOST": "server.invalid", "DECKHAND_SEED_USER": "me", "DECKHAND_SEED_PASSWORD": "stand-in",
            "DECKHAND_SEED_NAME": "sandbox", "DECKHAND_SEED_SCREEN": "actions",
            "DECKHAND_SEED_ACTIONS_REPOS": "acme/web,acme/ops", "DECKHAND_SEED_ACTIONS_RUNS": runs, "DECKHAND_SEED_ACTIONS_DETAIL": detail,
        ]
        app.launch()
        let server = app.staticTexts["sandbox"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.tap()
        let failed = app.buttons["actions.run.10"]
        if !failed.waitForExistence(timeout: 10) { app.buttons["Server"].firstMatch.tap() }
        XCTAssertTrue(failed.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["actions.run.11"].exists)
        let list = XCTAttachment(screenshot: app.screenshot()); list.name = "runs"; list.lifetime = .keepAlways; add(list)
        failed.tap()
        XCTAssertTrue(app.staticTexts["✗ go test ./..."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["actions.rerun"].exists)
        let d = XCTAttachment(screenshot: app.screenshot()); d.name = "failed"; d.lifetime = .keepAlways; add(d)
    }
}
