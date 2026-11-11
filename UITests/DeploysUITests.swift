import XCTest

/// Deploys on a disposable server with git and a bare repo (see LiveDeployTests): create, see it live, remove.
final class DeploysUITests: XCTestCase {
    func testCreateDeployRemove() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"], let repo = env["DECKHAND_DEPLOY_REPO"] else {
            throw XCTSkip("No test server")
        }
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        app.launchEnvironment["DECKHAND_SEED_HOST"] = host
        app.launchEnvironment["DECKHAND_SEED_PORT"] = env["DECKHAND_UPTIME_PORT"] ?? "22"
        app.launchEnvironment["DECKHAND_SEED_USER"] = env["DECKHAND_UPTIME_USER"] ?? "me"
        app.launchEnvironment["DECKHAND_SEED_PASSWORD"] = password
        app.launchEnvironment["DECKHAND_SEED_NAME"] = "sandbox"
        app.launchEnvironment["DECKHAND_SEED_TRUST"] = "1"
        app.launchEnvironment["DECKHAND_SEED_RUN"] = "server|"
        app.launch()
        let row = app.buttons["dashboard.deploys"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        var tries = 0
        while !row.isHittable && tries < 8 { app.swipeUp(); tries += 1 }
        row.tap()
        let new = app.buttons["apps.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 30))
        new.tap()
        let name = app.textFields["newapp.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap(); name.typeText("demo")
        let r = app.textFields["newapp.repo"]; r.tap(); r.typeText(repo)
        let s = app.textFields["newapp.start"]; s.tap(); s.typeText("python3 server.py")
        let h = app.textFields["newapp.health"]; h.tap(); h.typeText("http://127.0.0.1:8088/")
        app.swipeUp()
        app.switches["newapp.auto"].switches.firstMatch.tap()
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "wizard"; a.lifetime = .keepAlways; add(a)
        app.buttons["newapp.deploy"].tap()
        let demo = app.buttons["app.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30))
        demo.tap()
        let live = app.buttons["deploy.live"]
        var t = 0
        while !live.exists && t < 20 { sleep(3); app.swipeDown(); t += 1 }
        XCTAssertTrue(live.waitForExistence(timeout: 10))
        sleep(1)
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "live"; b.lifetime = .keepAlways; add(b)
        let remove = app.buttons["Remove app"]
        t = 0
        while !remove.isHittable && t < 6 { app.swipeUp(); t += 1 }
        remove.tap()
        app.buttons["Stop and remove"].tap()
        XCTAssertTrue(app.staticTexts["Removed."].waitForExistence(timeout: 30))
    }
}
