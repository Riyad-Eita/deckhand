import Foundation

/// Editing a file on the server by hand: load it with a fingerprint, save only if nobody changed it meanwhile.
public enum FileEditing {
    /// Files up to this size open in the editor.
    public static let maxBytes = 512 * 1024

    /// Prints the file's SHA-256 (`@@sha <hex>`), then its content.
    public static func loadCommand(_ path: String) -> String {
        let p = ShellQuote.quote(path)
        return "printf '@@sha %s\\n' \"$(sha256sum -- \(p) | cut -c1-64)\" && cat -- \(p)"
    }

    /// Splits the load output into fingerprint and content.
    public static func parseLoad(_ out: String) -> (sha: String, content: String)? {
        guard out.hasPrefix("@@sha "), let nl = out.firstIndex(of: "\n") else { return nil }
        let sha = String(out[out.index(out.startIndex, offsetBy: 6)..<nl])
        guard sha.count == 64 else { return nil }
        return (sha, String(out[out.index(after: nl)...]))
    }

    /// Writes `content` only if the file still has fingerprint `expected` (prints `@@changed` and exits 3
    /// otherwise). Writing into the file keeps its owner and permissions. Prints `@@saved <new sha>`.
    public static func saveCommand(_ path: String, content: String, expected: String) -> String {
        let p = ShellQuote.quote(path)
        let b64 = Data(content.utf8).base64EncodedString()
        return """
        [ "$(sha256sum -- \(p) 2>/dev/null | cut -c1-64)" = \(ShellQuote.quote(expected)) ] || { echo '@@changed'; exit 3; }
        printf %s \(ShellQuote.quote(b64)) | base64 -d > \(p) || exit 1
        printf '@@saved %s\\n' "$(sha256sum -- \(p) | cut -c1-64)"
        """
    }

    public enum SaveResult: Equatable { case saved(sha: String), changed, failed(String) }

    public static func parseSave(stdout: String, stderr: String, exitCode: Int32) -> SaveResult {
        if stdout.contains("@@changed") { return .changed }
        if exitCode == 0, let line = stdout.split(separator: "\n").first(where: { $0.hasPrefix("@@saved ") }) {
            return .saved(sha: String(line.dropFirst(8)))
        }
        return .failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The save failed for lack of rights (offer saving as root).
    public static func needsRoot(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("permission denied") || m.contains("operation not permitted")
    }

    /// The same save as root, as a reversible change (backup, change history, rollback).
    public static func rootChange(_ path: String, content: String) -> ConfigChange {
        let b64 = Data(content.utf8).base64EncodedString()
        return ConfigChange(
            title: "Edit \((path as NSString).lastPathComponent)", files: [path],
            apply: "printf %s \(ShellQuote.quote(b64)) | base64 -d > \(ShellQuote.quote(path))")
    }
}

/// Undo and redo for a text being edited: snapshots, with quick typing folded into one step.
public struct EditHistory: Sendable {
    private(set) var undoStack: [String] = []
    private(set) var redoStack: [String] = []
    private var current: String
    private var lastChange: Date?
    /// Changes closer together than this are one undo step.
    public var coalesce: TimeInterval = 1.2

    public init(_ text: String) { current = text }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Records that the text is now `text`.
    public mutating func record(_ text: String, at date: Date = Date()) {
        guard text != current else { return }
        let folds = lastChange.map { date.timeIntervalSince($0) < coalesce } ?? false
        if !(folds && !undoStack.isEmpty) { undoStack.append(current) }
        current = text
        redoStack = []
        lastChange = date
    }

    /// The text before the last step, or nil.
    public mutating func undo() -> String? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        current = previous
        lastChange = nil
        return previous
    }

    public mutating func redo() -> String? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        current = next
        lastChange = nil
        return next
    }

    /// After saving or reloading: start a fresh history from `text`.
    public mutating func reset(_ text: String) { self = EditHistory(text) }
}
