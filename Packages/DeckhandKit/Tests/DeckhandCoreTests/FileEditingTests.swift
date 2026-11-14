import Foundation
import Testing
@testable import DeckhandCore

@Suite struct FileEditingTests {
    @Test func loadAndSaveParsing() throws {
        let sha = String(repeating: "a", count: 64)
        let loaded = try #require(FileEditing.parseLoad("@@sha \(sha)\nline 1\nline 2\n"))
        #expect(loaded.sha == sha && loaded.content == "line 1\nline 2\n")
        #expect(FileEditing.parseLoad("cat: nope: No such file") == nil)
        #expect(FileEditing.parseSave(stdout: "@@saved \(sha)\n", stderr: "", exitCode: 0) == .saved(sha: sha))
        #expect(FileEditing.parseSave(stdout: "@@changed\n", stderr: "", exitCode: 3) == .changed)
        #expect(FileEditing.parseSave(stdout: "", stderr: "sh: 2: cannot create /etc/x: Permission denied\n", exitCode: 2)
                == .failed("sh: 2: cannot create /etc/x: Permission denied"))
        #expect(FileEditing.needsRoot("cannot create /etc/hosts: Permission denied"))
        #expect(!FileEditing.needsRoot("No space left on device"))
        let cmd = FileEditing.saveCommand("/tmp/it's here.conf", content: "a = 1\n", expected: sha)
        #expect(cmd.contains(#"'/tmp/it'\''s here.conf'"#))
        #expect(cmd.contains(Data("a = 1\n".utf8).base64EncodedString()))
        #expect(FileEditing.rootChange("/etc/hosts", content: "x").files == ["/etc/hosts"])
    }

    @Test func undoRedoWithCoalescing() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var h = EditHistory("hello")
        h.record("hello w", at: t0)
        h.record("hello wo", at: t0.addingTimeInterval(0.3))     // same step
        h.record("hello world", at: t0.addingTimeInterval(0.6))  // same step
        h.record("hello world!", at: t0.addingTimeInterval(5))   // new step
        #expect(h.canUndo && !h.canRedo)
        #expect(h.undo() == "hello world")
        #expect(h.undo() == "hello")
        #expect(h.undo() == nil)
        #expect(h.redo() == "hello world")
        #expect(h.redo() == "hello world!")
        #expect(h.redo() == nil)
        // Typing after undo drops the redo steps.
        _ = h.undo()
        h.record("hello world?", at: t0.addingTimeInterval(20))
        #expect(!h.canRedo)
        h.reset("saved")
        #expect(!h.canUndo && !h.canRedo)
    }
}
