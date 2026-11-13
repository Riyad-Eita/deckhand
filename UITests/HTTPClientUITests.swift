import XCTest

/// HTTP client: the demo collection's GET sent from the phone, then from the server's network (curl over SSH),
/// both answered with 200; the POST request shows its JSON body and bearer token. Needs a server with internet
/// access (TEST_RUNNER_DECKHAND_UPTIME_*).
final class HTTPClientUITests: XCTestCase {
    func testSendFromPhoneAndServer() throws {
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
        app.launchEnvironment["DECKHAND_SEED_HTTP"] = "1"
        app.launch()

        let entry = app.buttons["home.http"]
        var tries = 0
        while !(entry.exists && entry.isHittable) && tries < 6 { app.swipeUp(); tries += 1 }
        entry.tap()
        app.buttons["http.collection.Example API"].tap()
        app.buttons["http.request.Home page"].tap()

        // From this iPhone.
        let send = app.buttons["http.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        let status = app.staticTexts["http.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 40))
        XCTAssertEqual(status.label, "200")
        XCTAssertEqual(app.staticTexts["http.sentFrom"].label, "via this iPhone")

        // From the server.
        app.buttons["http.via"].tap()
        app.buttons["sandbox"].tap()
        XCTAssertTrue(app.staticTexts["Sent with curl on the server, so it reaches addresses only that server can see (localhost, private networks)."].waitForExistence(timeout: 5))
        send.tap()
        let viaServer = NSPredicate(format: "label == 'via sandbox'")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: viaServer, object: app.staticTexts["http.sentFrom"])], timeout: 60), .completed)
        XCTAssertEqual(status.label, "200")
        XCTAssertTrue(app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS[c] 'Example Domain'")).firstMatch.waitForExistence(timeout: 5))
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "response"; s.lifetime = .keepAlways; add(s)

        // The POST request: JSON body and bearer token from the environment.
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["http.request.Create item"].tap()
        XCTAssertTrue(app.textViews["http.body"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.textViews["http.body"].value as? String ?? "").contains("Deck chair"))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Not set in this environment'")).firstMatch.exists)
        let s2 = XCTAttachment(screenshot: app.screenshot()); s2.name = "post"; s2.lifetime = .keepAlways; add(s2)
    }
}
