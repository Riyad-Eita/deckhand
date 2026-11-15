import Foundation
import Testing
@testable import DeckhandCore

struct MacControlTests {
    /// Runs a command the way an SSH login on a Mac does (zsh) — or sh where zsh is missing.
    func run(_ command: String, stdin: String? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: "/bin/zsh") ? "/bin/zsh" : "/bin/sh")
        p.arguments = ["-c", command]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = out; p.standardInput = inp
        try p.run()
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
        try inp.fileHandleForWriting.close()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test func checkedReportsSuccessAndFailure() throws {
        #expect(MacControl.outcome(try run(MacControl.checked("true", failure: "x"))) == .ok)
        #expect(MacControl.outcome(try run(MacControl.checked("false", failure: "shortcut"))) == .failed("shortcut"))
    }

    @Test func openTellsLinksFromApps() throws {
        #expect(MacControl.open("https://example.com")?.contains("open 'https://example.com'") == true)
        #expect(MacControl.open("Safari")?.contains("open -a 'Safari'") == true)
        #expect(MacControl.open("  ") == nil)
        // Names can't break out of the quotes.
        #expect(MacControl.open("x'; rm -rf ~; '")?.contains(#"'x'\''; rm -rf ~; '\'''"#) == true)
    }

    @Test func outcomesAndShortcutLists() {
        #expect(MacControl.outcome("something\n@@ok\n") == .ok)
        #expect(MacControl.outcome("@@err screen\n") == .failed("screen"))
        #expect(MacControl.outcome("") == .failed("error"))
        #expect(MacControl.shortcuts("Morning\n\nResize Image\n@@ok\n") == ["Morning", "Resize Image"])
    }

    @Test func keepAwakeIsBounded() {
        #expect(MacControl.keepAwake(hours: 99).contains("-t 86400"))
        #expect(MacControl.keepAwake(hours: 0).contains("-t 3600"))
    }
}
