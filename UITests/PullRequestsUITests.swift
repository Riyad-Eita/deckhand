import XCTest

/// Pull requests (seeded `gh` output, no server or GitHub needed): the list, a PR with checks, an AI review
/// (canned answer) and its diff, and the actions.
final class PullRequestsUITests: XCTestCase {
    func testListDetailAndReview() throws {
        let list = "R\t" + #"[{"number":42,"title":"Cache the session lookup","repository":{"nameWithOwner":"acme/web"},"author":{"login":"ann"},"updatedAt":"2026-11-28T09:00:00Z","url":"u","isDraft":false}]"#
            + "\nM\t" + #"[{"number":7,"title":"Bump the image to 1.4","repository":{"nameWithOwner":"acme/ops"},"author":{"login":"me"},"updatedAt":"2026-11-27T09:00:00Z","url":"u","isDraft":true}]"#
        let detail = #"{"title":"Cache the session lookup","body":"Sessions were read from the database on every request.","author":{"login":"ann"},"baseRefName":"main","headRefName":"session-cache","additions":38,"deletions":6,"files":[{"path":"web/session.go","additions":30,"deletions":6},{"path":"web/session_test.go","additions":8,"deletions":0}],"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"},{"conclusion":"SUCCESS"},{"status":"IN_PROGRESS"}]}"#
            + "|@@diff|diff --git a/web/session.go b/web/session.go|@@ -10,6 +10,12 @@ func Load(id string) (*Session, error) {|-\treturn db.Session(id)|+\tif s, ok := cache.Get(id); ok {|+\t\treturn s, nil|+\t}|+\ts, err := db.Session(id)|+\tcache.Set(id, s, 5*time.Minute)|+\treturn s, err"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "DECKHAND_RESET": "1", "DECKHAND_SEED_SKIPAUTH": "1", "DECKHAND_SEED_TRUST": "1",
            "DECKHAND_SEED_HOST": "server.invalid", "DECKHAND_SEED_USER": "me", "DECKHAND_SEED_PASSWORD": "stand-in",
            "DECKHAND_SEED_NAME": "sandbox", "DECKHAND_SEED_SCREEN": "pullRequests",
            "DECKHAND_SEED_PRS": list, "DECKHAND_SEED_PR_DETAIL": detail,
            "DECKHAND_SEED_EXPLAIN": "SUMMARY: Caches sessions for five minutes instead of reading the database every time.\nRISKS:\n- web/session.go: a logged-out session stays valid for up to 5 minutes\n- No test covers cache expiry",
        ]
        app.launch()
        let server = app.staticTexts["sandbox"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.tap()
        let pr = app.buttons["pr.acme/web#42"]
        if !pr.waitForExistence(timeout: 10) { app.buttons["Server"].firstMatch.tap() }
        XCTAssertTrue(pr.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["pr.acme/ops#7"].exists)
        let l = XCTAttachment(screenshot: app.screenshot()); l.name = "list"; l.lifetime = .keepAlways; add(l)
        pr.tap()
        let summarize = app.buttons["pr.summarize"]
        XCTAssertTrue(summarize.waitForExistence(timeout: 10))
        summarize.tap()
        XCTAssertTrue(app.staticTexts["No test covers cache expiry"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["pr.merge"].exists && app.buttons["pr.approve"].exists)
        let d = XCTAttachment(screenshot: app.screenshot()); d.name = "detail"; d.lifetime = .keepAlways; add(d)
    }
}
