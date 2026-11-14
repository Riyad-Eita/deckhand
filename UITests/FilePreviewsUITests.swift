import XCTest

/// Previews in the file browser (TEST_RUNNER_DECKHAND_UPTIME_*, DECKHAND_PREVIEW_TEST=1). The harness puts
/// ~/dh-preview/{preview.png, preview.pdf, app.log} on the server and appends a "tick N" line to app.log every second:
/// the image and the PDF open in Quick Look with Share, and following the log shows new lines as they come.
final class FilePreviewsUITests: XCTestCase {
    func testPreviewsAndFollow() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DECKHAND_PREVIEW_TEST"] == "1", let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else {
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
        app.launch()
        let server = app.staticTexts["sandbox"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.tap()
        app.buttons["Server"].tap()
        let files = app.buttons["dashboard.files"]
        XCTAssertTrue(files.waitForExistence(timeout: 40))
        files.tap()
        let folder = app.staticTexts["dh-preview"]
        var t = 0
        while !folder.waitForExistence(timeout: 3) && t < 6 { app.swipeUp(); t += 1 }
        folder.tap()

        // Image in Quick Look, with Share.
        app.staticTexts["preview.png"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["preview.quicklook"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["preview.share"].waitForExistence(timeout: 5))
        sleep(2)
        let png = XCTAttachment(screenshot: app.screenshot()); png.name = "image"; png.lifetime = .keepAlways; add(png)
        app.navigationBars.buttons.firstMatch.tap()

        // PDF.
        app.staticTexts["preview.pdf"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["preview.quicklook"].waitForExistence(timeout: 30))
        sleep(2)
        let pdf = XCTAttachment(screenshot: app.screenshot()); pdf.name = "pdf"; pdf.lifetime = .keepAlways; add(pdf)
        app.navigationBars.buttons.firstMatch.tap()

        // Log: follow shows new lines.
        app.staticTexts["app.log"].tap()
        let follow = app.buttons["viewer.follow"]
        XCTAssertTrue(follow.waitForExistence(timeout: 20))
        follow.tap()
        let ticks = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'tick '"))
        XCTAssertTrue(ticks.firstMatch.waitForExistence(timeout: 20))
        let before = ticks.count
        sleep(5)
        XCTAssertGreaterThan(ticks.count, before, "new lines arrive while following")
        let log = XCTAttachment(screenshot: app.screenshot()); log.name = "follow"; log.lifetime = .keepAlways; add(log)
        follow.tap()
    }
}
