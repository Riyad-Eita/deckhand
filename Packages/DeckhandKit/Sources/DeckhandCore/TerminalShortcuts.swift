import Foundation

/// Hardware keyboard shortcuts in the terminal. Everything else (Ctrl, Option as Meta, Esc, arrows, function keys)
/// goes to the server as the terminal sends it.
public enum TerminalShortcut: Sendable, Hashable {
    case newTab, closeTab, nextTab, previousTab, tab(Int)
    case clear
    case larger, smaller, defaultSize

    /// Every shortcut with its key, whether Shift is part of it, and its title (for the iPad shortcut overview).
    public static let all: [(input: String, shift: Bool, action: TerminalShortcut, title: String)] =
        [("t", false, .newTab, String(localized: "New Tab")),
         ("w", false, .closeTab, String(localized: "Close Tab")),
         ("]", true, .nextTab, String(localized: "Next Tab")),
         ("[", true, .previousTab, String(localized: "Previous Tab")),
         ("k", false, .clear, String(localized: "Clear")),
         ("=", false, .larger, String(localized: "Larger Text")),
         ("+", false, .larger, String(localized: "Larger Text")),
         ("-", false, .smaller, String(localized: "Smaller Text")),
         ("0", false, .defaultSize, String(localized: "Default Text Size"))]
        + (1...9).map { (String($0), false, .tab($0), String(localized: "Tab \($0)")) }

    /// The shortcut for Cmd + `input` (with or without Shift).
    public static func action(input: String, shift: Bool) -> TerminalShortcut? {
        all.first { $0.input == input.lowercased() && $0.shift == shift }?.action
    }

    /// What Cmd+K sends: clear the local scrollback (ED 3), then Ctrl+L so the shell redraws its prompt.
    public static let clearLocal = "\u{1B}[3J"
    public static let clearRemote = "\u{0C}"
}
