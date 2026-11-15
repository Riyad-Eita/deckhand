import Foundation

/// Small things on a Mac that was added as a server, over SSH as the signed-in user: a screenshot, a Shortcut, an
/// app or link, text to the clipboard, staying awake. Each command prints `@@ok` or `@@err <reason>` lines.
public enum MacControl {
    /// Where the screenshot lands on the Mac (read and removed by the app).
    public static let shotPath = "/tmp/deckhand-screen.jpg"

    /// A JPEG of the main display. Needs Screen Recording permission for remote logins on the Mac.
    public static let screenshotCommand =
        "rm -f \(shotPath); screencapture -x -t jpg -D 1 \(shotPath) 2>&1 | tail -n 1; if [ -s \(shotPath) ]; then echo @@ok; else echo '@@err screen'; fi"

    /// The user's Shortcuts, one per line.
    public static let listShortcutsCommand = "shortcuts list 2>/dev/null"

    public static func runShortcut(_ name: String) -> String {
        checked("shortcuts run \(ShellQuote.quote(name))", failure: "shortcut")
    }

    /// Runs `command` (POSIX: works in zsh, the Mac's login shell) and reports @@ok or @@err with its last lines.
    static func checked(_ command: String, failure: String) -> String {
        "out=$(\(command) 2>&1); rc=$?; printf '%s\\n' \"$out\" | tail -n 3; if [ $rc -eq 0 ]; then echo @@ok; else echo \"@@err \(failure)\"; fi"
    }

    /// A link (http, https, mailto …) or an app by name.
    public static func open(_ target: String) -> String? {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let url = URL(string: t), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "x-apple.systempreferences"].contains(scheme) {
            return checked("open \(ShellQuote.quote(t))", failure: "open")
        }
        return checked("open -a \(ShellQuote.quote(t))", failure: "app")
    }

    /// Text onto the Mac's clipboard (sent through stdin, never on the command line).
    public static let clipboardCommand = "pbcopy && echo @@ok || echo \"@@err clipboard\""

    /// Stay awake for `hours` (the display may sleep, the Mac doesn't). Replaces an earlier one from Deckhand.
    public static func keepAwake(hours: Int) -> String {
        let s = max(1, min(hours, 24)) * 3600
        return "pkill -f '^caffeinate -i -s -t' 2>/dev/null; nohup caffeinate -i -s -t \(s) >/dev/null 2>&1 & echo @@ok"
    }

    public static let stopKeepAwakeCommand = "pkill -f '^caffeinate -i -s -t'; echo @@ok"

    /// `@@awake` while Deckhand keeps the Mac awake, else `@@normal`.
    public static let awakeStatusCommand = "if pgrep -f '^caffeinate -i -s -t' >/dev/null; then echo @@awake; else echo @@normal; fi"

    public enum Outcome: Equatable { case ok, failed(String) }

    public static func outcome(_ out: String) -> Outcome {
        if out.contains("@@ok") { return .ok }
        if let line = out.split(separator: "\n").first(where: { $0.hasPrefix("@@err") }) {
            let what = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            return .failed(what.isEmpty ? "error" : what)
        }
        return .failed("error")
    }

    public static func shortcuts(_ out: String) -> [String] {
        out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("@@") }
    }
}
