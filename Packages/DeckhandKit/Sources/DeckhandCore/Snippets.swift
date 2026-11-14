import Foundation

/// Saved commands: one tap sends them to the terminal. `{{name}}` or `{{name:default}}` placeholders are asked for
/// before sending. A snippet belongs to one server or to all.
public struct Snippet: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var title: String
    public var command: String
    /// nil: every server.
    public var serverID: UUID?
    public var uses = 0
    public var lastUsed: Date?

    public init(title: String, command: String, serverID: UUID? = nil) {
        self.title = title; self.command = command; self.serverID = serverID
    }

    public struct Placeholder: Sendable, Hashable, Identifiable {
        public var name: String
        public var defaultValue: String
        public var id: String { name }
    }

    /// The placeholders in order of first appearance; a repeated name is asked once.
    public var placeholders: [Placeholder] {
        var out: [Placeholder] = []
        for m in command.matches(of: /\{\{\s*([A-Za-z_][A-Za-z0-9_ -]*?)\s*(?::([^}]*))?\}\}/) {
            let name = String(m.output.1).trimmingCharacters(in: .whitespaces)
            if out.contains(where: { $0.name == name }) { continue }
            out.append(Placeholder(name: name, defaultValue: m.output.2.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""))
        }
        return out
    }

    /// The command with placeholders filled in (missing values use the default).
    public func filled(_ values: [String: String]) -> String {
        command.replacing(/\{\{\s*([A-Za-z_][A-Za-z0-9_ -]*?)\s*(?::([^}]*))?\}\}/) { m in
            let name = String(m.output.1).trimmingCharacters(in: .whitespaces)
            if let v = values[name], !v.isEmpty { return v }
            return m.output.2.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
    }

    /// A title for a command saved from the chat: its first words, without sudo.
    public static func suggestedTitle(for command: String) -> String {
        let first = command.split(separator: "\n").first.map(String.init) ?? command
        var words = first.split(separator: " ").map(String.init)
        if words.first == "sudo" { words.removeFirst() }
        let t = words.prefix(4).joined(separator: " ")
        return t.count > 40 ? String(t.prefix(40)) + "…" : t
    }

    /// Snippets for a server: its own first, then the global ones; most used first within each.
    public static func forServer(_ id: UUID?, in all: [Snippet]) -> [Snippet] {
        let order = { (a: Snippet, b: Snippet) in (a.uses, a.lastUsed ?? .distantPast) > (b.uses, b.lastUsed ?? .distantPast) }
        let own = id.map { sid in all.filter { $0.serverID == sid }.sorted(by: order) } ?? []
        return own + all.filter { $0.serverID == nil }.sorted(by: order)
    }
}
