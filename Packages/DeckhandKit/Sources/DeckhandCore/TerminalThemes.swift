import Foundation

/// Color schemes and font sizes for the terminal. Colors are hex strings so they can be checked without UIKit.
public struct TerminalTheme: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var background: String
    public var foreground: String
    public var cursor: String
    /// The 16 ANSI colors: black, red, green, yellow, blue, magenta, cyan, white, then the bright ones.
    public var ansi: [String]
    public var isLight: Bool

    public static let all: [TerminalTheme] = [midnight, solarizedDark, solarizedLight, paper, phosphor]
    public static let `default` = midnight

    public static func named(_ id: String) -> TerminalTheme { all.first { $0.id == id } ?? .default }

    public static let midnight = TerminalTheme(
        id: "midnight", name: "Midnight", background: "#000000", foreground: "#EBEBEB", cursor: "#EBEBEB",
        ansi: ["#000000", "#E0605A", "#5FC970", "#E6C25A", "#5B8DEF", "#C57BDB", "#4FC1D6", "#D0D0D0",
               "#6B6B6B", "#FF7A73", "#7BE38B", "#FFDB74", "#7DA8FF", "#DE96F2", "#6ADCF0", "#FFFFFF"],
        isLight: false)

    public static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized Dark", background: "#002B36", foreground: "#839496", cursor: "#93A1A1",
        ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
               "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"],
        isLight: false)

    public static let solarizedLight = TerminalTheme(
        id: "solarized-light", name: "Solarized Light", background: "#FDF6E3", foreground: "#586E75", cursor: "#586E75",
        ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
               "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"],
        isLight: true)

    public static let paper = TerminalTheme(
        id: "paper", name: "Paper", background: "#FAFAF7", foreground: "#1F1F1F", cursor: "#1F1F1F",
        ansi: ["#1F1F1F", "#B3261E", "#2E7D32", "#8A6100", "#1A56DB", "#8E24AA", "#00796B", "#BDBDBD",
               "#616161", "#D32F2F", "#388E3C", "#A87900", "#3B6FF0", "#AB47BC", "#00897B", "#E0E0E0"],
        isLight: true)

    public static let phosphor = TerminalTheme(
        id: "phosphor", name: "Phosphor", background: "#050A05", foreground: "#4AF626", cursor: "#4AF626",
        ansi: ["#050A05", "#3FBF2A", "#4AF626", "#7DF55E", "#2E9E1E", "#5FD847", "#8BFA72", "#B8FCA8",
               "#1F4D17", "#52D33A", "#6BFF4C", "#A0FF88", "#3CC22A", "#7AE85F", "#A6FF92", "#E0FFD6"],
        isLight: false)

    /// "#RRGGBB" → components 0…1.
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// WCAG contrast ratio between two colors.
    public static func contrast(_ a: String, _ b: String) -> Double {
        func lum(_ hex: String) -> Double {
            guard let c = rgb(hex) else { return 0 }
            func ch(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

public enum TerminalFont {
    public static let range: ClosedRange<Double> = 8...28
    public static let `default`: Double = 13

    public static func clamp(_ size: Double) -> Double { min(range.upperBound, max(range.lowerBound, size.rounded())) }
}
