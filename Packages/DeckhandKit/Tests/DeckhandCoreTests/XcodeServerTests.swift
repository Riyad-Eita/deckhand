import Foundation
import Testing
@testable import DeckhandCore

struct XcodeServerTests {
    @Test func detectsAMac() {
        let i = XcodeServer.parseDetect("@@os Darwin\n@@macos 26.1\n@@xcode Xcode 27.2 Build version 27C5040a \n@@nokeychain\n")
        #expect(i.isMac && i.macOS == "26.1" && i.xcode == "27.2 (27C5040a)" && i.keychainLocked)
        #expect(!XcodeServer.parseDetect("@@os Linux\n").isMac)
    }

    @Test func projectsPreferWorkspaces() {
        let p = XcodeServer.parseProjects("""
        @@project /Users/me/Developer/shop/Shop.xcodeproj
        @@project /Users/me/Developer/shop/Shop.xcworkspace
        @@project /Users/me/Developer/notes/Notes.xcodeproj
        """)
        #expect(p.map(\.name) == ["Shop", "Notes"] && p[0].isWorkspace && p[1].folder == "/Users/me/Developer/notes")
        #expect(XcodeServer.parseSchemes("Command line invocation:\n{\"project\":{\"name\":\"Notes\",\"schemes\":[\"Notes\",\"NotesTests\"]}}") == ["Notes", "NotesTests"])
        #expect(XcodeServer.parseSchemes("{\"workspace\":{\"name\":\"Shop\",\"schemes\":[\"Shop\"]}}") == ["Shop"])
    }

    @Test func summarizesBuildsTestsAndUploads() {
        let s = XcodeServer.summarize("""
        @@step test
        /src/A.swift:3:5: error: cannot find 'x' in scope
        /src/B.swift:9:1: warning: unused variable
        Test Case '-[NotesTests.NotesTests testAdd]' failed (0.010 seconds).
        Executed 4 tests, with 1 failure (0 unexpected) in 0.020 (0.022) seconds
        @@result failed
        """)
        #expect(s.ok == false && s.errors.count == 1 && s.warnings == 1 && s.testsRun == 4 && s.testsFailed == 1)
        #expect(s.failedTests == ["NotesTests.NotesTests testAdd"])
        let u = XcodeServer.summarize("@@nokeychain\n@@step archive\n@@archive /Users/me/.deckhand/xcode/Notes-1.xcarchive\n@@step upload\n@@uploaded\n@@result ok\n")
        #expect(u.ok == true && u.uploaded && u.archive?.hasSuffix(".xcarchive") == true && u.hints.count == 1)
    }

    @Test func uploadsUseTheKeyOnTheMac() {
        let p = XcodeServer.Project(path: "/Users/me/Developer/notes/Notes.xcodeproj")
        let c = XcodeServer.jobCommand(.upload, project: p, scheme: "Notes", key: .init(keyID: "ABC123", issuerID: "iss-1"))
        #expect(c.contains("-authenticationKeyPath \"$HOME/.appstoreconnect/private_keys/AuthKey_ABC123.p8\""))
        #expect(c.contains("-exportArchive") && c.contains("<string>upload</string>") && c.contains("@@nokey"))
        #expect(!XcodeServer.jobCommand(.build, project: p, scheme: "Notes").contains("authenticationKey"))
    }

    /// Real xcodebuild on this Mac (DECKHAND_XCODE_TEST=1): a tiny generated app with one unit test is found,
    /// built and tested — with the same scripts the app runs over SSH.
    @Test func buildsAndTestsOnThisMac() async throws {
        guard ProcessInfo.processInfo.environment["DECKHAND_XCODE_TEST"] == "1" else { return }
        let root = FileManager.default.temporaryDirectory.appending(path: "xc-\(UUID().uuidString.prefix(6))").path
        let dir = root + "/Developer/Tiny"
        try FileManager.default.createDirectory(atPath: dir + "/App", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/Tests", withIntermediateDirectories: true)
        try """
        name: Tiny
        options: { bundleIdPrefix: com.example }
        targets:
          Tiny:
            type: application
            platform: iOS
            deploymentTarget: "17.0"
            sources: [App]
            settings: { GENERATE_INFOPLIST_FILE: YES, CODE_SIGNING_ALLOWED: NO }
          TinyTests:
            type: bundle.unit-test
            platform: iOS
            deploymentTarget: "17.0"
            sources: [Tests]
            dependencies: [{ target: Tiny }]
            settings: { GENERATE_INFOPLIST_FILE: YES, CODE_SIGNING_ALLOWED: NO }
        schemes:
          Tiny:
            build: { targets: { Tiny: all } }
            test: { targets: [TinyTests] }
        """.write(toFile: dir + "/project.yml", atomically: true, encoding: .utf8)
        try """
        import SwiftUI
        func sum(_ a: Int, _ b: Int) -> Int { a + b }
        @main struct TinyApp: App { var body: some Scene { WindowGroup { Text("Tiny") } } }
        """.write(toFile: dir + "/App/App.swift", atomically: true, encoding: .utf8)
        try """
        import XCTest
        @testable import Tiny
        final class TinyTests: XCTestCase { func testAdd() { XCTAssertEqual(sum(2, 3), 5) } }
        """.write(toFile: dir + "/Tests/TinyTests.swift", atomically: true, encoding: .utf8)
        let sh = LocalShell()
        _ = try await sh.run("cd '\(dir)' && xcodegen generate -q", timeout: .seconds(60))

        let projects = XcodeServer.parseProjects(try await sh.run("HOME='\(root)' /bin/sh -c \(ShellQuote.quote(XcodeServer.projectsCommand()))", timeout: .seconds(30)).stdout)
        let project = try #require(projects.first { $0.name == "Tiny" })
        #expect(XcodeServer.parseSchemes(try await sh.run(XcodeServer.schemesCommand(project), timeout: .seconds(60)).stdout).contains("Tiny"))

        let build = XcodeServer.summarize(try await sh.run(XcodeServer.jobCommand(.build, project: project, scheme: "Tiny"), timeout: .seconds(600)).stdout)
        #expect(build.ok == true, "\(build.errors)")
        let test = XcodeServer.summarize(try await sh.run("/bin/bash -c " + ShellQuote.quote(XcodeServer.jobCommand(.test, project: project, scheme: "Tiny")), timeout: .seconds(900)).stdout)
        #expect(test.ok == true && test.testsRun == 1 && test.testsFailed == 0, "\(test)")
        _ = try await sh.run("rm -rf '\(root)'", timeout: .seconds(30))
    }
}
