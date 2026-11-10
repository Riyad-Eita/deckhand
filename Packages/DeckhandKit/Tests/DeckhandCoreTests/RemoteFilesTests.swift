import Foundation
import Testing
@testable import DeckhandCore

@Suite struct RemoteFilesTests {
    static let sample = "/home/me/app\nrw\n"
        + "d/d/4096/1700000000.5/755/src/\0"
        + "f/f/1234/1700000100.0/644/README.md/\0"
        + "f/f/10/1700000200.0/600/.env/\0"
        + "l/d/7/1700000300.0/777/current/releases/v2\0"
        + "l/N/7/1700000300.0/777/broken/missing\0"
        + "f/f/3/1700000000.0/644/two\nlines and\ttab/\0"
        + "p/p/0/1700000000.0/644/fifo/\0"

    @Test func parsesEntries() throws {
        let folder = try #require(RemoteFiles.parse(Self.sample))
        #expect(folder.path == "/home/me/app")
        #expect(folder.writable)
        #expect(!folder.truncated)
        #expect(folder.entries.count == 7)
        let src = try #require(folder.entries.first { $0.name == "src" })
        #expect(src.kind == .folder && src.opensAsFolder && src.mode == "755")
        let current = try #require(folder.entries.first { $0.name == "current" })
        #expect(current.kind == .link && current.opensAsFolder && current.linkTarget == "releases/v2")
        let broken = try #require(folder.entries.first { $0.name == "broken" })
        #expect(broken.kind == .link && !broken.opensAsFolder)
        #expect(folder.entries.contains { $0.name == "two\nlines and\ttab" })
        #expect(folder.entries.first { $0.name == "fifo" }?.kind == .other)
        let readme = try #require(folder.entries.first { $0.name == "README.md" })
        #expect(readme.size == 1234 && readme.modified == Date(timeIntervalSince1970: 1_700_000_100) && readme.linkTarget == nil)
    }

    @Test func rejectsOutputWithoutPath() {
        #expect(RemoteFiles.parse("") == nil)
        #expect(RemoteFiles.parse("sh: cd: no such file\n") == nil)
        let empty = RemoteFiles.parse("/srv\nro\n")
        #expect(empty?.entries.isEmpty == true && empty?.writable == false)
    }

    @Test func marksTruncatedListings() throws {
        let many = (0...RemoteFiles.limit).map { "f/f/1/1/644/f\($0)/\0" }.joined()
        let folder = try #require(RemoteFiles.parse("/tmp\nrw\n" + many))
        #expect(folder.truncated)
        #expect(folder.entries.count == RemoteFiles.limit)
    }

    @Test func sortsFoldersFirstAndHidesDotfiles() throws {
        let entries = try #require(RemoteFiles.parse(Self.sample)).entries
        let byName = RemoteFiles.sorted(entries, by: .name, showHidden: false).map(\.name)
        #expect(byName == ["current", "src", "broken", "fifo", "README.md", "two\nlines and\ttab"])
        #expect(RemoteFiles.sorted(entries, by: .name, showHidden: true).map(\.name).contains(".env"))
        let bySize = RemoteFiles.sorted(entries, by: .size, showHidden: false).map(\.name)
        #expect(Array(bySize.prefix(3)) == ["current", "src", "README.md"])
        let byDate = RemoteFiles.sorted(entries, by: .modified, showHidden: true).map(\.name)
        #expect(Array(byDate.prefix(2)) == ["current", "src"])
        #expect(byDate[2] == "broken")
    }

    @Test func validatesNames() throws {
        #expect(try RemoteFiles.validName("  notes.txt ") == "notes.txt")
        #expect(throws: RemoteFiles.NameProblem.empty) { try RemoteFiles.validName("  ") }
        #expect(throws: RemoteFiles.NameProblem.dots) { try RemoteFiles.validName("..") }
        #expect(throws: RemoteFiles.NameProblem.slash) { try RemoteFiles.validName("a/b") }
        #expect(throws: RemoteFiles.NameProblem.tooLong) { try RemoteFiles.validName(String(repeating: "x", count: 256)) }
    }

    @Test func protectsRootTopLevelAndRelativePaths() {
        for p in ["/", "/etc", "/home", "//", "relative/path", "/home/me/../..", "~/x"] {
            #expect(RemoteFiles.isProtected(p), "\(p)")
            #expect(RemoteFiles.deleteCommand(p) == nil)
        }
        #expect(!RemoteFiles.isProtected("/home/me/app"))
        let cmd = RemoteFiles.deleteCommand("/home/me/it's here")
        #expect(cmd?.contains("rm -rf -- '/home/me/it'\\''s here'") == true)
        #expect(cmd?.contains("Refusing to delete the home folder") == true)
    }

    @Test func quotesRenameAndMkdir() {
        let mv = RemoteFiles.renameCommand(in: "/srv/app", from: "a b", to: "$(reboot)")
        #expect(mv.contains("mv -- '/srv/app/a b' '/srv/app/$(reboot)'"))
        #expect(mv.contains("already exists"))
        #expect(RemoteFiles.makeFolderCommand(in: "/", name: "x'y") == "mkdir -- '/x'\\''y'")
    }

    @Test func shortensToolErrors() {
        let r = CommandResult(stdout: "", stderr: "mv: cannot move 'a' to 'b': Permission denied\n", exitCode: 1)
        #expect(RemoteFiles.message(r, or: "Can't rename a") == "Can't rename a: Permission denied")
        let own = CommandResult(stdout: "", stderr: "Something with that name already exists.\n", exitCode: 3)
        #expect(RemoteFiles.message(own, or: "x") == "Something with that name already exists.")
        #expect(RemoteFiles.message(CommandResult(stdout: "", stderr: "", exitCode: 1), or: "fallback") == "fallback")
    }

    /// The real command against this Mac's shell can't run (BSD find has no -printf, BSD stat no -c), so check the
    /// pieces that matter: header, GNU path, fallback and the entry limit.
    @Test func listCommandShape() {
        let c = RemoteFiles.listCommand("~/my app")
        #expect(c.hasPrefix("cd -- ~/'my app' && pwd -P && "))
        #expect(c.contains("-printf '%y/%Y/%s/%T@/%m/%f/%l\\0'"))
        #expect(c.contains("head -z -n \(RemoteFiles.limit + 1)"))
        #expect(c.contains("stat -c '%s/%Y/%a'"))
        #expect(!c.contains("\n"))
    }
}
