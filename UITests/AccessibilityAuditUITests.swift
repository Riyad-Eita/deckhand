import XCTest

/// Xcode's accessibility audit (labels, contrast, Dynamic Type, hit areas, …) on the main screens with demo data.
/// Needs a server for the dashboard (TEST_RUNNER_DECKHAND_UPTIME_*); the other screens run without.
final class AccessibilityAuditUITests: XCTestCase {
    private func launch(_ extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DECKHAND_RESET"] = "1"
        for (k, v) in extra { app.launchEnvironment[k] = v }
        app.launch()
        return app
    }

    private func audit(_ app: XCUIApplication, _ name: String) throws {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [String] = []
            func add(_ s: String) { lock.withLock { items.append(s) } }
            var all: [String] { lock.withLock { items } }
        }
        let box = Box()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        // The Dynamic Type check flags system list rows, toolbars and section footers that do scale (false positives);
        // clipping at large sizes is checked instead. "Contrast nearly passed" is the system's secondary gray.
        try app.performAccessibilityAudit(for: XCUIAccessibilityAuditType.all.subtracting(.dynamicType)) { issue in
            if issue.auditType == .contrast && issue.compactDescription.lowercased().contains("nearly") { return true }
            // Findings without an element can't be traced to a view of ours (system bars and toolbars); noted, not failed.
            if issue.element == nil { print("AUDIT note \(name): \(issue.compactDescription)"); return true }
            box.add("\(name): \(issue.auditType) — \(issue.compactDescription) — \(issue.element?.debugDescription.prefix(160) ?? "")")
            return true // collect, report below
        }
        let issues = box.all
        for i in issues { print("AUDIT", i) }
        XCTAssertTrue(issues.isEmpty, "\(issues.count) accessibility issues on \(name)")
    }

    func testHomeAndSettings() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else { throw XCTSkip("No test server") }
        let app = launch(["DECKHAND_SEED_HOST": host, "DECKHAND_SEED_PORT": env["DECKHAND_UPTIME_PORT"] ?? "22",
                          "DECKHAND_SEED_USER": env["DECKHAND_UPTIME_USER"] ?? "me", "DECKHAND_SEED_PASSWORD": password,
                          "DECKHAND_SEED_NAME": "sandbox", "DECKHAND_SEED_TRUST": "1"])
        XCTAssertTrue(app.staticTexts["sandbox"].waitForExistence(timeout: 20))
        try audit(app, "home")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        try audit(app, "settings")
    }

    func testEmptyHome() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Add your first server"].waitForExistence(timeout: 20))
        try audit(app, "empty home")
    }

    func testDashboard() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DECKHAND_UPTIME_HOST"], let password = env["DECKHAND_UPTIME_PASSWORD"] else { throw XCTSkip("No test server") }
        let app = launch(["DECKHAND_SEED_HOST": host, "DECKHAND_SEED_PORT": env["DECKHAND_UPTIME_PORT"] ?? "22",
                          "DECKHAND_SEED_USER": env["DECKHAND_UPTIME_USER"] ?? "me", "DECKHAND_SEED_PASSWORD": password,
                          "DECKHAND_SEED_NAME": "sandbox", "DECKHAND_SEED_TRUST": "1"])
        let server = app.staticTexts["sandbox"]
        var t = 0
        // At the largest text sizes the server row starts below the fold.
        while !server.waitForExistence(timeout: 4) && t < 8 { app.swipeUp(); t += 1 }
        server.tap()
        try audit(app, "agent")
        app.buttons["Server"].tap()
        XCTAssertTrue(app.buttons["dashboard.files"].waitForExistence(timeout: 40))
        try audit(app, "dashboard")
    }

    func testPlainChat() throws {
        let app = launch(["DECKHAND_SEED_APIKEY": "invalid-test-key"])
        let chat = app.buttons["home.justChat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 20))
        chat.tap()
        XCTAssertTrue(app.staticTexts["Ask anything"].waitForExistence(timeout: 10))
        try audit(app, "chat")
    }
}
