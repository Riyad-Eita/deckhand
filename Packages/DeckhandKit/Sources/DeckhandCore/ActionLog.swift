import Foundation

/// What an agent did in a task — commands, files read and changed, searches — with times and results, for any
/// engine (Claude Code and Codex events arrive as the same tool calls), and as Markdown to export.
public enum ActionLog {
    public enum Kind: String, Sendable {
        case command, read, write, edit, list, search, files, other
        public var symbol: String {
            switch self {
            case .command: "terminal"
            case .read: "doc.text"
            case .write: "square.and.pencil"
            case .edit: "pencil.line"
            case .list: "folder"
            case .search: "magnifyingglass"
            case .files: "doc.on.doc"
            case .other: "puzzlepiece.extension"
            }
        }
        public var changes: Bool { self == .write || self == .edit || self == .files }
    }

    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: String
        public var date: Date?
        public var kind: Kind
        /// The command, the path(s), the pattern, or the tool's name.
        public var detail: String
        /// nil while there's no result yet.
        public var failed: Bool?
        /// First lines of the result.
        public var output: String
    }

    public static func entries(_ messages: [Message]) -> [Entry] {
        var results: [String: ToolResult] = [:]
        for m in messages {
            for b in m.blocks { if case .toolResult(let r) = b { results[r.toolUseID] = r } }
        }
        return messages.flatMap { m in
            m.toolCalls.map { call in
                let (kind, detail) = describe(call)
                let r = results[call.id]
                let out = r.map { String($0.content.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).joined(separator: "\n").prefix(600)) } ?? ""
                return Entry(id: call.id, date: m.date, kind: kind, detail: detail, failed: r.map(\.isError), output: out)
            }
        }
    }

    static func describe(_ c: ToolCall) -> (Kind, String) {
        func s(_ k: String) -> String { c.input[k]?.stringValue ?? "" }
        switch c.name {
        case "run_command": return (.command, s("command"))
        case "read_file": return (.read, s("path"))
        case "write_file": return (.write, s("path"))
        case "edit_file": return (.edit, s("path"))
        case "list_directory": return (.list, s("path"))
        case "search": return (.search, s("pattern"))
        case "file_change":
            let paths = (c.input["paths"]?.arrayValue ?? []).compactMap(\.stringValue)
            return (.files, paths.joined(separator: ", "))
        default:
            let name = c.name.replacingOccurrences(of: "__", with: " · ")
            return (.other, name)
        }
    }

    public struct Totals: Sendable, Hashable {
        public var commands = 0, changedFiles = 0, failed = 0
        public var first: Date?, last: Date?
    }

    public static func totals(_ entries: [Entry]) -> Totals {
        var t = Totals()
        t.commands = entries.filter { $0.kind == .command }.count
        t.changedFiles = Set(entries.filter(\.kind.changes).flatMap { $0.detail.components(separatedBy: ", ") }).count
        t.failed = entries.filter { $0.failed == true }.count
        let dates = entries.compactMap(\.date)
        t.first = dates.min(); t.last = dates.max()
        return t
    }

    /// The log as Markdown (for sharing or keeping with a ticket).
    public static func markdown(title: String, server: String, folder: String, engine: String, entries: [Entry], now: Date = Date()) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let t = totals(entries)
        var out = """
        # \(title)

        - Server: \(server)
        - Folder: \(folder)
        - Engine: \(engine)
        - Actions: \(entries.count) (\(t.commands) commands, \(t.changedFiles) files changed, \(t.failed) failed)
        - Exported: \(iso.string(from: now))

        """
        for e in entries {
            let time = e.date.map { iso.string(from: $0) } ?? "—"
            let status = e.failed == true ? " ✗" : ""
            out += "\n### \(time) · \(e.kind.rawValue)\(status)\n\n```\n\(e.detail)\n```\n"
            if !e.output.isEmpty { out += "\n<details><summary>Output</summary>\n\n```\n\(e.output)\n```\n</details>\n" }
        }
        return out
    }
}
