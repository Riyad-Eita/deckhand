import XCTest

/// Preview a deployed app (TEST_RUNNER_DECKHAND_UPTIME_*): its public address opens in the in-app browser with Reload
/// and Share, and "Show the agent" starts a task with a screenshot of the page waiting in the composer.
final class AppPreviewUITests: XCTestCase {
    func testOpenShareAndShowTheAgent() throws {
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
        app.launch()
        let server = app.staticTexts["sandbox"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.tap()
        app.buttons["Server"].tap()
        let row = app.buttons["dashboard.webApps"]
        XCTAssertTrue(row.waitForExistence(timeout: 40))
        var t = 0
        while !row.isHittable && t < 8 { app.swipeUp(); t += 1 }
        row.tap()

        let address = app.textFields["webapp.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 20))
        address.tap()
        address.typeText("example.com")
        app.buttons["webapp.openAddress"].tap()
        XCTAssertTrue(app.buttons["browser.share"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS 'documentation examples'")).firstMatch.waitForExistence(timeout: 30))
        app.buttons["browser.reload"].tap()
        let page = XCTAttachment(screenshot: app.screenshot()); page.name = "page"; page.lifetime = .keepAlways; add(page)

        app.buttons["browser.showAgent"].tap()
        let own = app.buttons["Your model key"]
        XCTAssertTrue(own.waitForExistence(timeout: 10))
        own.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.images"].waitForExistence(timeout: 10), "the screenshot waits in the composer")
        let input = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue((input.value as? String ?? "").contains("example.com"))
        let chat = XCTAttachment(screenshot: app.screenshot()); chat.name = "task"; chat.lifetime = .keepAlways; add(chat)
    }
}
