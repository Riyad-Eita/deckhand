import XCTest

/// Your own model on the disposable server (TEST_RUNNER_DECKHAND_UPTIME_*, DECKHAND_OLLAMA_TEST=1): installs Ollama
/// with the sudo password if needed, downloads the smallest model, measures it, uses it for chats, and gets an answer
/// in a plain chat — through the SSH tunnel, the model only listens on the server's localhost. On a server too small
/// to run a model, a stand-in for Ollama's API on port 11434 answers instead (the install itself is checked by hand).
final class LocalModelUITests: XCTestCase {
    func testInstallMeasureAndChat() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_OLLAMA_TEST"] == "1", let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else {
            throw XCTSkip("No test server")
        }
        let model = "qwen3:0.6b"
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
        let serverTab = app.buttons["Server"]
        XCTAssertTrue(serverTab.waitForExistence(timeout: 20))
        serverTab.tap()
        let row = app.buttons["dashboard.localModel"]
        XCTAssertTrue(row.waitForExistence(timeout: 40))
        var t = 0
        while !row.isHittable && t < 12 { app.swipeUp(); t += 1 }
        row.tap()

        XCTAssertTrue(app.staticTexts["Processor"].waitForExistence(timeout: 30))
        let install = app.buttons["localModel.install"], download = app.buttons["localModel.download"]
        let installed = app.descendants(matching: .any)["localModel.model.\(model)"]
        t = 0
        while !install.exists && !download.exists && !installed.exists && t < 20 { sleep(1); t += 1 }
        if install.exists {
            app.buttons["localModel.choice.\(model)"].tap()
            install.tap()
            let pw = app.secureTextFields.firstMatch
            if pw.waitForExistence(timeout: 20) { pw.typeText(password); app.alerts.buttons["Continue"].tap() }
        } else if !installed.exists {
            app.buttons["localModel.choice.\(model)"].tap()
            download.tap()
        }
        XCTAssertTrue(installed.waitForExistence(timeout: 1200), "model downloaded")
        let speed = app.descendants(matching: .any)["localModel.speed"]
        if !speed.waitForExistence(timeout: 300) {
            app.descendants(matching: .any)["localModel.model.\(model)"].swipeLeft()
            app.buttons["Measure"].tap()
            XCTAssertTrue(speed.waitForExistence(timeout: 300), "speed measured")
        }
        let use = app.buttons["localModel.use.\(model)"]
        if use.exists { use.tap() }
        XCTAssertTrue(app.staticTexts["In use"].waitForExistence(timeout: 5))
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "local-model"; s.lifetime = .keepAlways; add(s)

        // A plain chat now talks to the server's model.
        app.navigationBars.buttons.firstMatch.tap()
        let back = app.navigationBars.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        sleep(1)
        back.tap()
        let newChat = app.buttons["home.newChat"]
        t = 0
        while !(newChat.exists && newChat.isHittable) && t < 8 { app.swipeUp(); t += 1 }
        newChat.tap()
        XCTAssertTrue(app.staticTexts["Ask anything"].waitForExistence(timeout: 10))
        let input = app.textFields["plainchat.input"].exists ? app.textFields["plainchat.input"] : app.textViews["plainchat.input"]
        input.tap()
        input.typeText("Reply with one word: hello")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForNonExistence(timeout: 240))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'hello'")).count >= 2, "an answer from the model")
        let c = XCTAttachment(screenshot: app.screenshot()); c.name = "chat"; c.lifetime = .keepAlways; add(c)
    }
}
