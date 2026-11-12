import Foundation
import Testing
@testable import DeckhandCore

struct CheckpointsTests {
    @Test func snapshotDiffUndo() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cp-\(UUID().uuidString.prefix(6))").path
        let proj = home + "/proj"
        let sh = LocalShell()
        func run(_ c: String) async throws -> String { try await sh.run("HOME='\(home)' /bin/sh -c \(ShellQuote.quote(c))", timeout: .seconds(30)).stdout }
        _ = try await run("mkdir -p '\(proj)/src' '\(proj)/node_modules/x' && cd '\(proj)' && printf 'one\\ntwo\\n' > src/a.txt && echo keep > b.txt && echo dep > node_modules/x/i.js && git init -q && git add -A && git -c user.name=t -c user.email=t@x commit -qm init")
        let id = "task-1"
        #expect(try await run(Checkpoints.createCommand(task: id, folder: proj)).hasPrefix("@@checkpoint "))
        #expect(try await run(Checkpoints.createCommand(task: id, folder: proj)).hasPrefix("@@unchanged "))

        // The agent works: edits a file, adds one, deletes one.
        _ = try await run("cd '\(proj)' && printf 'one\\nTWO\\n' > src/a.txt && echo new > c.txt && rm b.txt")
        _ = try await run(Checkpoints.createCommand(task: id, folder: proj))
        let changes = Checkpoints.parseChanges(try await run(Checkpoints.changesCommand(task: id, folder: proj)))
        #expect(Set(changes.map { "\($0.kind.rawValue) \($0.path)" }) == ["M src/a.txt", "A c.txt", "D b.txt"])
        let a = try #require(changes.first { $0.path == "src/a.txt" })
        #expect(a.diff.contains("-two") && a.diff.contains("+TWO") && a.added == 1 && a.removed == 1)

        // Undo one file, then everything.
        #expect(try await run(Checkpoints.undoCommand(task: id, folder: proj, paths: ["src/a.txt"])).contains("@@ok"))
        #expect(try String(contentsOfFile: proj + "/src/a.txt", encoding: .utf8) == "one\ntwo\n")
        #expect(FileManager.default.fileExists(atPath: proj + "/c.txt"))
        _ = try await run(Checkpoints.undoCommand(task: id, folder: proj))
        #expect(!FileManager.default.fileExists(atPath: proj + "/c.txt"))
        #expect(try String(contentsOfFile: proj + "/b.txt", encoding: .utf8) == "keep\n")
        #expect(Checkpoints.parseChanges(try await run(Checkpoints.changesCommand(task: id, folder: proj))).isEmpty)
        // The project's own repository was never touched.
        #expect(try await run("cd '\(proj)' && git status --porcelain && git log --oneline | wc -l").trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        _ = try await run(Checkpoints.removeCommand(task: id))
        #expect(!FileManager.default.fileExists(atPath: home + "/.deckhand/checkpoints/task-1"))
        _ = try await sh.run("rm -rf '\(home)'", timeout: .seconds(10))
    }

    @Test func homeRelativeFolders() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cp-\(UUID().uuidString.prefix(6))").path
        let sh = LocalShell()
        func run(_ c: String) async throws -> String { try await sh.run("HOME='\(home)' /bin/sh -c \(ShellQuote.quote(c))", timeout: .seconds(30)).stdout }
        _ = try await run("mkdir -p \"$HOME/p\" && echo a > \"$HOME/p/a.txt\"")
        #expect(try await run(Checkpoints.createCommand(task: "t2", folder: "~/p")).hasPrefix("@@checkpoint "))
        _ = try await run("echo b > \"$HOME/p/a.txt\"")
        #expect(Checkpoints.parseChanges(try await run(Checkpoints.changesCommand(task: "t2", folder: "~/p"))).map(\.path) == ["a.txt"])
        _ = try await sh.run("rm -rf '\(home)'", timeout: .seconds(10))
    }

    @Test func tooBigFoldersAreSkipped() async throws {
        let c = Checkpoints.createCommand(task: "t", folder: "~")
        #expect(c.contains("@@toobig") && c.contains("head -n 20001"))
    }
}
