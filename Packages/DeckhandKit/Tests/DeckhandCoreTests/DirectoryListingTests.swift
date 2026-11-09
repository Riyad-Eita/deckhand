import Foundation
import Testing
@testable import DeckhandCore

@Suite struct DirectoryListingTests {
    @Test func parsesAndSorts() {
        let out = "/home/dev/app\n@@git\n.github/\nsrc/\nDocs/\nnode_modules/\n"
        let l = DirectoryListing.parse(out)
        #expect(l == DirectoryListing(path: "/home/dev/app", folders: ["Docs", "node_modules", "src", ".github"], isGitRepo: true))
        #expect(DirectoryListing.parse("cd: no such file") == nil)
    }

    @Test func paths() {
        #expect(DirectoryListing.parent(of: "/home/dev") == "/home")
        #expect(DirectoryListing.parent(of: "/home") == "/")
        #expect(DirectoryListing.parent(of: "/") == "/")
        #expect(DirectoryListing.join("/", "etc") == "/etc")
        #expect(DirectoryListing.join("/home", "dev") == "/home/dev")
    }

    @Test func listsLocally() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dl-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir.appending(path: "b"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appending(path: "A"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appending(path: "file.txt").path, contents: Data())
        let r = try await LocalShell().run(DirectoryListing.command(dir.path), timeout: .seconds(10))
        let l = try #require(DirectoryListing.parse(r.stdout))
        #expect(l.folders == ["A", "b"])
        #expect(!l.isGitRepo)
    }
}
