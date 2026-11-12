import CryptoKit
import Foundation

/// Environment files (`.env`) kept on the phone with their history: edited as variables, written to the server as
/// 0600 files (through SFTP into a private folder — the values never appear in a command line), and rolled back to
/// any earlier version. Changes made on the server since the last write are noticed.
public enum EnvVault {
    // MARK: .env text

    public enum Line: Sendable, Hashable {
        case entry(key: String, value: String, quote: Character?, export: Bool)
        /// Comments, blank lines, anything that isn't KEY=VALUE — kept as it is.
        case other(String)
    }

    public static func parse(_ text: String) -> [Line] {
        text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            var t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return .other(line) }
            var export = false
            if t.hasPrefix("export ") { export = true; t = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq2 = t.firstIndex(of: "=") else { return .other(line) }
            _ = eq
            let key = t[..<eq2].trimmingCharacters(in: .whitespaces)
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_.\-]*$"#, options: .regularExpression) != nil else { return .other(line) }
            var value = String(t[t.index(after: eq2)...])
            var quote: Character?
            if let first = value.first, first == "\"" || first == "'", value.count >= 2, value.last == first {
                quote = first
                value = String(value.dropFirst().dropLast())
            }
            return .entry(key: key, value: value, quote: quote, export: export)
        }
    }

    public static func serialize(_ lines: [Line]) -> String {
        var text = lines.map { l -> String in
            switch l {
            case .other(let s): return s
            case .entry(let k, let v, let q, let e):
                let needsQuote = q != nil || v.contains(" ") || v.contains("#") || v.contains("\"")
                let quote = q ?? (needsQuote ? "\"" : nil)
                let body = quote.map { "\($0)\(v)\($0)" } ?? v
                return (e ? "export " : "") + "\(k)=\(body)"
            }
        }.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        return text
    }

    /// The variables in order (later duplicates win, like most loaders).
    public static func variables(_ lines: [Line]) -> [(key: String, value: String)] {
        lines.compactMap { if case .entry(let k, let v, _, _) = $0 { (k, v) } else { nil } }
    }

    /// Sets a variable (changing it in place, or appending it).
    public static func set(_ key: String, _ value: String, in lines: [Line]) -> [Line] {
        var out = lines
        if let i = out.lastIndex(where: { if case .entry(let k, _, _, _) = $0 { k == key } else { false } }),
           case .entry(_, _, let q, let e) = out[i] {
            out[i] = .entry(key: key, value: value, quote: q, export: e)
        } else {
            if case .other(let s)? = out.last, s.isEmpty { out.removeLast() }
            out.append(.entry(key: key, value: value, quote: nil, export: false))
        }
        return out
    }

    public static func remove(_ key: String, from lines: [Line]) -> [Line] {
        lines.filter { if case .entry(let k, _, _, _) = $0 { k != key } else { true } }
    }

    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: History

    public struct Version: Sendable, Hashable, Codable, Identifiable {
        public var id: UUID
        public var date: Date
        public var content: String
        /// "Imported from the server", "Edited", "Restored …".
        public var note: String
        public init(id: UUID = UUID(), date: Date = Date(), content: String, note: String) {
            self.id = id; self.date = date; self.content = content; self.note = note
        }
    }

    /// One managed file on one server, with its versions (newest last, at most `keep`).
    public struct File: Sendable, Hashable, Codable, Identifiable {
        public var id: UUID
        public var path: String
        public var versions: [Version]
        /// The hash of what the app last wrote or read, to notice changes made on the server.
        public var lastKnownHash: String
        public static let keep = 30
        public init(id: UUID = UUID(), path: String, versions: [Version], lastKnownHash: String) {
            self.id = id; self.path = path; self.versions = versions; self.lastKnownHash = lastKnownHash
        }
        public var current: Version? { versions.last }
        public mutating func add(_ v: Version) {
            versions.append(v)
            if versions.count > Self.keep { versions.removeFirst(versions.count - Self.keep) }
        }
    }

    // MARK: Server side

    public static func isValidPath(_ p: String) -> Bool {
        !p.isEmpty && !p.hasSuffix("/") && p.range(of: #"^[~/A-Za-z0-9._\-][A-Za-z0-9._\-/~ ]*$"#, options: .regularExpression) != nil
            && !p.contains("..")
    }

    /// `@@missing`, or `@@mode <octal>` then `@@content` and the file.
    public static func readCommand(_ path: String) -> String {
        let f = ServerTools.shellPath(path)
        return """
        f=\(f); [ -f "$f" ] || { echo '@@missing'; exit 0; }
        [ -r "$f" ] || { echo '@@unreadable'; exit 0; }
        echo "@@mode $(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")"
        echo '@@content'; cat "$f"
        """
    }

    public struct Read: Sendable, Hashable {
        public var exists: Bool
        public var readable: Bool
        public var mode: String
        public var content: String
    }

    public static func parseRead(_ out: String) -> Read {
        if out.hasPrefix("@@missing") { return Read(exists: false, readable: false, mode: "", content: "") }
        if out.hasPrefix("@@unreadable") { return Read(exists: true, readable: false, mode: "", content: "") }
        guard let r = out.range(of: "@@content\n") else { return Read(exists: false, readable: false, mode: "", content: "") }
        let head = out[..<r.lowerBound]
        let mode = head.split(separator: "\n").first { $0.hasPrefix("@@mode ") }.map { String($0.dropFirst(7)) } ?? ""
        return Read(exists: true, readable: true, mode: mode, content: String(out[r.upperBound...]))
    }

    /// The private folder an upload lands in first (0700).
    public static let stagingDir = "~/.deckhand/vault"
    public static let prepareStagingCommand = "mkdir -p ~/.deckhand/vault && chmod 700 ~/.deckhand ~/.deckhand/vault && echo '@@ok'"

    /// Moves the uploaded file into place as 0600 (keeping the old file as `<path>.deckhand-prev` for the server's own
    /// rollback) and prints its hash.
    public static func installCommand(uploaded: String, path: String) -> String {
        let f = ServerTools.shellPath(path)
        return """
        u=\(ShellQuote.quote(uploaded)); f=\(f)
        chmod 600 "$u" && mkdir -p "$(dirname "$f")" || { echo '@@failed'; exit 0; }
        [ -f "$f" ] && cp -p "$f" "$f.deckhand-prev" && chmod 600 "$f.deckhand-prev"
        mv -f "$u" "$f" && echo "@@mode $(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" && echo '@@ok'
        """
    }
}
