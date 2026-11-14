import Foundation
import Testing
@testable import DeckhandCore

@Suite struct TerminalThemesTests {
    @Test func everyThemeIsComplete() {
        #expect(Set(TerminalTheme.all.map(\.id)).count == TerminalTheme.all.count)
        for t in TerminalTheme.all {
            #expect(t.ansi.count == 16, "\(t.id)")
            for hex in t.ansi + [t.background, t.foreground, t.cursor] { #expect(TerminalTheme.rgb(hex) != nil, "\(t.id) \(hex)") }
            // Body text stays readable (WCAG AA for normal text is 4.5).
            #expect(TerminalTheme.contrast(t.foreground, t.background) >= 4.5, "\(t.id)")
            #expect(t.isLight == ((TerminalTheme.rgb(t.background)?.r ?? 0) > 0.5), "\(t.id)")
        }
    }

    @Test func lookupAndFontSizes() {
        #expect(TerminalTheme.named("paper").name == "Paper")
        #expect(TerminalTheme.named("nope") == .default)
        #expect(TerminalFont.clamp(3) == 8 && TerminalFont.clamp(40) == 28 && TerminalFont.clamp(14.6) == 15)
        #expect(TerminalTheme.contrast("#000000", "#FFFFFF") > 20)
    }
}
