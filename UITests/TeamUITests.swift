import XCTest

/// People on the disposable server (TEST_RUNNER_DECKHAND_UPTIME_*, DECKHAND_TEAM_TEST=1): invite someone read-only,
/// enter the sudo password once, see the QR code, then remove the account again.
final class TeamUITests: XCTestCase {
    func testInviteAndRemove() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_TEAM_TEST"] == "1", let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else { throw XCTSkip("No test server") }
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
        let row = app.buttons["dashboard.team"]
        XCTAssertTrue(row.waitForExistence(timeout: 40))
        var t = 0
        while !row.isHittable && t < 15 { app.swipeUp(); t += 1 }
        row.tap()

        let invite = app.buttons["team.invite"]
        XCTAssertTrue(invite.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Nobody else yet"].waitForExistence(timeout: 20))
        invite.tap()
        let person = app.textFields["invite.person"]
        XCTAssertTrue(person.waitForExistence(timeout: 5))
        person.tap(); person.typeText("Uitest Anna")
        XCTAssertEqual(app.textFields["invite.user"].value as? String, "uitest")
        app.buttons["Read only"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "invite"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["invite.create"].tap()

        let field = app.secureTextFields["Password"]
        if field.waitForExistence(timeout: 15) {
            field.typeText(password)
            app.buttons["Continue"].tap()
        }
        XCTAssertTrue(app.images["team.qr"].waitForExistence(timeout: 30), "the invite code is shown")
        let qr = XCTAttachment(screenshot: app.screenshot()); qr.name = "code"; qr.lifetime = .keepAlways; add(qr)
        app.buttons["Done"].tap()

        let member = app.buttons.containing(.staticText, identifier: "Uitest Anna").firstMatch
        XCTAssertTrue(member.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Invited"].waitForExistence(timeout: 20))
        let list = XCTAttachment(screenshot: app.screenshot()); list.name = "people"; list.lifetime = .keepAlways; add(list)
        member.swipeLeft()
        app.buttons["Remove"].tap()
        app.buttons["team.remove.confirm"].firstMatch.tap()
        XCTAssertTrue(member.waitForNonExistence(timeout: 30))
    }
}
