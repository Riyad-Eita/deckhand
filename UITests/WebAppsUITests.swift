import XCTest

/// Web apps: a web server that only listens on the server's localhost (DECKHAND_WEB_APP_PORT) shows up in the list
/// and opens in the in-app browser through the SSH tunnel. The server must allow TCP forwarding.
final class WebAppsUITests: XCTestCase {
    func testOpenLocalhostAppThroughTunnel() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_WEB_HOST"], let key = env["DECKHAND_WEB_KEY"], let port = env["DECKHAND_WEB_APP_PORT"] else {
            throw XCTSkip("No server for the web apps test")
        }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_WEB_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_WEB_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_KEY"] = key
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()

        let row = app.buttons["dashboard.webApps"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 5 { app.swipeUp(); tries += 1 }
        row.tap()
        // Servers listen on many ports; open this one by number.
        let field = app.textFields["Other port"]
        var tries2 = 0
        while !(field.exists && field.isHittable) && tries2 < 8 { app.swipeUp(); tries2 += 1 }
        field.tap()
        field.typeText(port)
        app.buttons["Open"].tap()
        XCTAssertTrue(app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Hello from the server'")).firstMatch.waitForExistence(timeout: 30))
        let page = XCTAttachment(screenshot: app.screenshot()); page.name = "page"; page.lifetime = .keepAlways; add(page)
    }
}
