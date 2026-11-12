import XCTest

/// App Store Connect: demo data (no network) for the screens, and a live connect with a real API key
/// (TEST_RUNNER_DECKHAND_ASC_KEY="<key id>|<issuer>|<base64 .p8>", read-only, disconnects again).
final class AppStoreUITests: XCTestCase {
    func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }

    func launch(_ env: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_EXTRA"] = "web-1|example.com|me"
        for (k, v) in env { app.launchEnvironment[k] = v }
        app.launch()
        let row = app.buttons["home.appstore"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        return app
    }

    func testDemoAppsBuildsAndTesters() throws {
        for style in ["light", "dark"] {
            let app = launch(["DECKHAND_SEED_ASC": "demo", "DECKHAND_APPEARANCE": style])
            let weather = app.buttons["asc.app.Weather Lab"]
            XCTAssertTrue(weather.waitForExistence(timeout: 20))
            XCTAssertTrue(app.staticTexts["In review"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["Approved, waiting for release"].exists)
            shot(app, "apps-\(style)")
            weather.tap()
            XCTAssertTrue(app.descendants(matching: .any)["asc.build.57"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS '2.3 · macOS'")).firstMatch.exists)
            let group = app.descendants(matching: .any)["asc.group.Early birds"].firstMatch
            var t = 0
            while !group.isHittable && t < 6 { app.swipeUp(); t += 1 }
            group.tap()
            let kim = app.staticTexts["kim@example.com"]
            t = 0
            while !kim.exists && t < 4 { app.swipeUp(); t += 1 }
            XCTAssertTrue(kim.waitForExistence(timeout: 5))
            shot(app, "app-\(style)")
            app.terminate()
        }
    }

    func testDraftAndPostAReply() throws {
        let app = launch(["DECKHAND_SEED_ASC": "demo", "DECKHAND_SEED_EXPLAIN": "Thanks for the report — the double entries are fixed in 2.4, which is in review now."])
        let weather = app.buttons["asc.app.Weather Lab"]
        XCTAssertTrue(weather.waitForExistence(timeout: 20))
        weather.tap()
        let reviews = app.buttons["asc.reviews"]
        XCTAssertTrue(reviews.waitForExistence(timeout: 20))
        reviews.tap()
        XCTAssertTrue(app.buttons["review.rv2"].waitForExistence(timeout: 20))
        app.buttons["1–2 ★"].tap()
        XCTAssertFalse(app.buttons["review.rv2"].exists)
        app.buttons["review.rv1"].tap()
        app.buttons["reply.draft"].tap()
        let text = app.textViews["reply.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue((text.value as? String)?.hasPrefix("Thanks for the report") == true)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "reply"; s.lifetime = .keepAlways; add(s)
        app.buttons["reply.post"].tap()
        app.buttons["Post reply"].tap()
        XCTAssertTrue(app.buttons["reply.post"].waitForNonExistence(timeout: 10))
    }

    func testConnectWithRealKey() throws {
        guard let key = ProcessInfo.processInfo.environment["DECKHAND_ASC_KEY"] else { throw XCTSkip("No App Store Connect key") }
        let app = launch(["DECKHAND_SEED_ASC_KEY": key])
        let connect = app.buttons["asc.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 20))
        shot(app, "connect")
        connect.tap()
        let deckhand = app.buttons.containing(NSPredicate(format: "identifier BEGINSWITH 'asc.app.Deckhand'")).firstMatch
        XCTAssertTrue(deckhand.waitForExistence(timeout: 60))
        deckhand.tap()
        XCTAssertTrue(app.staticTexts["Builds"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["On the App Store"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["More"].tap()
        app.buttons["Disconnect"].firstMatch.tap()
        app.buttons["Disconnect"].firstMatch.tap()
        XCTAssertTrue(app.buttons["asc.connect"].waitForExistence(timeout: 10))
    }
}
