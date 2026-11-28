import XCTest

/// Skills on a server (seeded list, no server needed): which CLI has each, and writing a new one.
final class SkillsUITests: XCTestCase {
    func testListAndWrite() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "DECKHAND_RESET": "1", "DECKHAND_SEED_SKIPAUTH": "1", "DECKHAND_SEED_TRUST": "1",
            "DECKHAND_SEED_HOST": "server.invalid", "DECKHAND_SEED_USER": "me", "DECKHAND_SEED_PASSWORD": "stand-in",
            "DECKHAND_SEED_NAME": "sandbox", "DECKHAND_SEED_SCREEN": "skills",
            "DECKHAND_SEED_SKILLS": "claude,deploy-web,Deploys the web app and checks it answers|codex,deploy-web,Deploys the web app and checks it answers|claude,pdf,Fill in and read PDF forms",
        ]
        app.launch()
        let server = app.staticTexts["sandbox"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.tap()
        let skill = app.buttons["skill.deploy-web"]
        if !skill.waitForExistence(timeout: 15) { app.buttons["Server"].firstMatch.tap() }
        XCTAssertTrue(skill.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["skill.pdf"].exists)
        let list = XCTAttachment(screenshot: app.screenshot()); list.name = "skills"; list.lifetime = .keepAlways; add(list)

        app.buttons["skills.add"].tap()
        app.buttons["Write a skill"].tap()
        let name = app.textFields["skill.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Restart Web")
        let save = app.buttons["skill.save"]
        XCTAssertFalse(save.isEnabled, "needs a description and instructions")
        XCTAssertTrue(app.staticTexts["Saved as restart-web. The description tells the agent when this skill fits."].exists)
        let form = XCTAttachment(screenshot: app.screenshot()); form.name = "write"; form.lifetime = .keepAlways; add(form)
    }
}
