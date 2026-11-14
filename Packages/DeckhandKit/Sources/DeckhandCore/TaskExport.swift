import Foundation

/// Finding old tasks again (title and content) and handing them on as Markdown.
public enum TaskExport {
    /// Whether a task matches `query` (every word, case- and accent-insensitive), and a short snippet around the
    /// first hit in the content (nil when only the title matched).
    public static func match(_ query: String, title: String, messages: [Message]) -> (matches: Bool, snippet: String?) {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return (true, nil) }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let body = messages.map(searchableText).joined(separator: "\n")
        let all = title + "\n" + body
        guard words.allSatisfy({ all.range(of: $0, options: options) != nil }) else { return (false, nil) }
        if words.allSatisfy({ title.range(of: $0, options: options) != nil }) { return (true, nil) }
        guard let hit = words.lazy.compactMap({ body.range(of: $0, options: options) }).first else { return (true, nil) }
        let start = body.index(hit.lowerBound, offsetBy: -40, limitedBy: body.startIndex) ?? body.startIndex
        let end = body.index(hit.upperBound, offsetBy: 60, limitedBy: body.endIndex) ?? body.endIndex
        let piece = body[start..<end].replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return (true, (start > body.startIndex ? "…" : "") + piece + (end < body.endIndex ? "…" : ""))
    }

    static func searchableText(_ m: Message) -> String {
        m.blocks.compactMap { b -> String? in
            switch b {
            case .text(let t): t
            case .toolUse(let c): c.input["command"]?.stringValue ?? c.input["path"]?.stringValue
            case .toolResult(let r): String(r.content.prefix(2000))
            default: nil
            }
        }.joined(separator: "\n")
    }

    /// The task as Markdown: who said what, commands with their (shortened) output. Secrets are masked.
    public static func markdown(title: String, server: String?, folder: String?, date: Date, messages: [Message]) -> String {
        var out = "# \(title)\n\n"
        let when = date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        out += [server.map { "Server: \($0)" }, folder.map { "Folder: `\($0)`" }, "Date: \(when)"].compactMap { $0 }.joined(separator: " · ") + "\n"
        for m in messages {
            for b in m.blocks {
                switch b {
                case .text(let t) where !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    out += m.role == .user ? "\n## You\n\n\(t)\n" : "\n\(t)\n"
                case .toolUse(let c):
                    if let command = c.input["command"]?.stringValue {
                        out += "\n```sh\n$ \(command)\n```\n"
                    } else {
                        let arg = c.input["path"]?.stringValue.map { " `\($0)`" } ?? ""
                        out += "\n_\(c.name)\(arg)_\n"
                    }
                case .toolResult(let r) where !r.content.isEmpty:
                    var text = r.content
                    if text.count > 3000 { text = String(text.prefix(3000)) + "\n… (\(r.content.count - 3000) more characters)" }
                    out += "\n```\n\(text)\n```\n"
                default: break
                }
            }
        }
        return Secrets.mask(out)
    }

    /// A file name for the export: the title without characters file systems dislike.
    public static func fileName(for title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|\n")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Task" : String(cleaned.prefix(60))) + ".md"
    }
}
