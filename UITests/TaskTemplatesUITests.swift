import XCTest

/// Task templates: made from an empty task, with a {{value}} that is asked for before the task starts.
final class TaskTemplatesUITests: XCTestCase {
    func testMakeFillAndStartATemplate() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "DECKHAND_RESET": "1", "DECKHAND_SEED_SKIPAUTH": "1", "DECKHAND_SEED_TRUST": "1",
            "DECKHAND_SEED_HOST": "server.invalid", "DECKHAND_SEED_USER": "me", "DECKHAND_SEED_PASSWORD": "stand-in",
            "DECKHAND_SEED_NAME": "web-1", "DECKHAND_SEED_APIKEY": "stand-in-key", "DECKHAND_SEED_EMPTYTASK": "1",
        ]
        app.launch()

        let new = app.buttons["template.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 30))
        new.tap()
        let title = app.textFields["snippet.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("Restart a service")
        let text = app.textViews["snippet.command"].exists ? app.textViews["snippet.command"] : app.textFields["snippet.command"]
        text.tap(); text.typeText("Restart {{service:nginx}} and show the last log lines")
        let form = XCTAttachment(screenshot: app.screenshot()); form.name = "new-template"; form.lifetime = .keepAlways; add(form)
        app.buttons["snippet.save"].tap()

        let template = app.buttons["template.Restart a service"]
        XCTAssertTrue(template.waitForExistence(timeout: 5))
        let list = XCTAttachment(screenshot: app.screenshot()); list.name = "templates"; list.lifetime = .keepAlways; add(list)
        template.tap()
        let value = app.textFields["snippet.value.service"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        value.typeText("redis")
        XCTAssertTrue(app.staticTexts["Restart redis and show the last log lines"].exists)
        app.buttons["snippet.run"].tap()
        // The task starts with the filled-in text (it then fails: the server doesn't exist).
        XCTAssertTrue(app.staticTexts["Restart redis and show the last log lines"].waitForExistence(timeout: 10))
        let started = XCTAttachment(screenshot: app.screenshot()); started.name = "started"; started.lifetime = .keepAlways; add(started)
    }
}
