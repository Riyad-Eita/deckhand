import Foundation

/// Search across servers, tasks and folders by typing, and actions in plain words: "restart nginx on web-1".
public enum CommandPalette {
    /// How well `query` matches `text` (higher is better): whole-word prefix > prefix > substring > letters in order.
    /// Nil when it doesn't match at all.
    public static func score(_ query: String, _ text: String) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces), t = text.lowercased()
        guard !q.isEmpty else { return 1 }
        if t == q { return 1_000 }
        if t.hasPrefix(q) {
            // "web" in "web-2" (a whole word) beats "web" in "webhook".
            let next = t.dropFirst(q.count).first
            return (next.map { !$0.isLetter && !$0.isNumber } ?? true ? 900 : 800) - min(t.count, 99)
        }
        if t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return 600 - min(t.count, 200) }
        if t.contains(q) { return 400 - min(t.count, 200) }
        var i = t.startIndex
        for c in q {
            guard let found = t[i...].firstIndex(of: c) else { return nil }
            i = t.index(after: found)
        }
        return 100 - min(t.count, 99)
    }

    public enum Verb: String, Sendable, CaseIterable {
        case restart, start, stop, status, logs, reload
        /// Needs root (runs through sudo).
        public var needsRoot: Bool { self == .restart || self == .start || self == .stop || self == .reload }
        public var disruptive: Bool { self == .stop }
    }

    public struct Action: Sendable, Hashable {
        public var verb: Verb
        public var service: String
        /// The server named in the text, if any ("on web-1").
        public var server: String?
    }

    /// "restart nginx on web-1", "logs of shop on prod", "status docker", "stop the redis service on db".
    public static func action(_ text: String) -> Action? {
        var words = text.lowercased().split(separator: " ").map(String.init).filter { !["the", "of", "for", "service"].contains($0) }
        guard let first = words.first, let verb = Verb(rawValue: first == "show" ? "status" : first == "log" ? "logs" : first) else { return nil }
        words.removeFirst()
        var server: String?
        if let on = words.firstIndex(where: { $0 == "on" || $0 == "at" || $0 == "@" }), on + 1 < words.count {
            server = words[(on + 1)...].joined(separator: " ")
            words.removeSubrange(on...)
        }
        guard words.count == 1, let service = words.first,
              service.range(of: #"^[a-z0-9@_.\-]+$"#, options: .regularExpression) != nil else { return nil }
        return Action(verb: verb, service: service, server: server)
    }

    /// The shell for an action (root actions go through the root runner, which adds sudo).
    public static func command(_ a: Action) -> String {
        let u = ShellQuote.quote(a.service)
        switch a.verb {
        case .status: return Services.statusCommand(a.service)
        case .logs: return Services.logsCommand(a.service, lines: 60)
        default: return "systemctl \(a.verb.rawValue) \(u) && systemctl is-active \(u)"
        }
    }
}
