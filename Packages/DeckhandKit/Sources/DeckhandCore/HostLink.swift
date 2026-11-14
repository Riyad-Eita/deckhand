import Foundation

/// Server links: `deckhand://add?host=…&user=…&port=…&name=…&jump=…` (shareable, also as a QR code) and plain
/// `ssh://user@host:port` URLs. A link only describes where a server is — it never carries a password or key, and
/// opening one never adds a server by itself: the import screen shows it first.
public enum HostLink {
    /// The link for one server, the inverse of `parse`.
    public static func link(for c: HostImport.Candidate) -> String {
        var parts = URLComponents()
        parts.scheme = "deckhand"
        parts.host = "add"
        var items = [URLQueryItem(name: "host", value: c.host), URLQueryItem(name: "user", value: c.user)]
        if c.port != 22 { items.append(URLQueryItem(name: "port", value: String(c.port))) }
        if !c.name.isEmpty, c.name != c.host { items.append(URLQueryItem(name: "name", value: c.name)) }
        if let jump = c.proxyJump { items.append(URLQueryItem(name: "jump", value: jump)) }
        parts.queryItems = items
        // `+` would read back as a space in some decoders; spell it out.
        return (parts.string ?? "deckhand://add").replacingOccurrences(of: "+", with: "%2B")
    }

    /// One server from a `deckhand://add` or `ssh://` URL; nil when it isn't one or a field is unsafe.
    public static func parse(_ url: URL) -> HostImport.Candidate? {
        switch url.scheme?.lowercased() {
        case "deckhand":
            guard url.host == "add" else { return nil }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? {
                items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            }
            guard let host = value("host"), isHost(host) else { return nil }
            let user = value("user") ?? "root"
            guard isUser(user) else { return nil }
            var port = 22
            if let p = value("port") {
                guard let n = Int(p), (1...65535).contains(n) else { return nil }
                port = n
            }
            let jump = value("jump")
            if let jump, !isJump(jump) { return nil }
            return HostImport.Candidate(name: value("name").map(cleanName) ?? host, host: host, port: port, user: user,
                                        proxyJump: jump)
        case "ssh":
            guard let host = url.host, isHost(host) else { return nil }
            let user = url.user ?? "root"
            guard isUser(user), url.password == nil else { return nil }
            let port = url.port ?? 22
            guard (1...65535).contains(port) else { return nil }
            return HostImport.Candidate(name: host, host: host, port: port, user: user)
        default:
            return nil
        }
    }

    /// Every link in `text`, one per line or separated by spaces (a pasted list, a scanned QR code).
    public static func parseAll(_ text: String) -> [HostImport.Candidate] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { word in
            let w = word.lowercased()
            guard w.hasPrefix("deckhand://add") || w.hasPrefix("ssh://") else { return nil }
            return URL(string: String(word)).flatMap(parse)
        }
    }

    /// A DNS name, IPv4 or IPv6 address — nothing that could smuggle an option or a second command.
    static func isHost(_ s: String) -> Bool {
        s.count <= 253 && !s.hasPrefix("-") && s.range(of: #"^[A-Za-z0-9._:\[\]-]+$"#, options: .regularExpression) != nil
    }

    static func isUser(_ s: String) -> Bool {
        s.count <= 64 && !s.hasPrefix("-") && s.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    /// A jump host alias or `[user@]host[:port]`.
    static func isJump(_ s: String) -> Bool {
        s.count <= 300 && !s.hasPrefix("-") && s.range(of: #"^[A-Za-z0-9._:@\[\]-]+$"#, options: .regularExpression) != nil
    }

    /// A display name: no control characters, at most 64 characters.
    static func cleanName(_ s: String) -> String {
        String(String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(64))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
