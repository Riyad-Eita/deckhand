import Foundation
import Testing
@testable import DeckhandCore

@Suite struct TerminalShortcutsTests {
    @Test func mapping() {
        #expect(TerminalShortcut.action(input: "t", shift: false) == .newTab)
        #expect(TerminalShortcut.action(input: "T", shift: false) == .newTab)
        #expect(TerminalShortcut.action(input: "w", shift: false) == .closeTab)
        #expect(TerminalShortcut.action(input: "]", shift: true) == .nextTab)
        #expect(TerminalShortcut.action(input: "[", shift: true) == .previousTab)
        #expect(TerminalShortcut.action(input: "3", shift: false) == .tab(3))
        #expect(TerminalShortcut.action(input: "k", shift: false) == .clear)
        #expect(TerminalShortcut.action(input: "=", shift: false) == .larger)
        #expect(TerminalShortcut.action(input: "0", shift: false) == .defaultSize)
        #expect(TerminalShortcut.action(input: "c", shift: false) == nil)   // copy stays with the system
        #expect(TerminalShortcut.action(input: "t", shift: true) == nil)
    }

    @Test func noDuplicateKeys() {
        let keys = TerminalShortcut.all.map { "\($0.input)\($0.shift)" }
        #expect(Set(keys).count == keys.count)
    }
}
