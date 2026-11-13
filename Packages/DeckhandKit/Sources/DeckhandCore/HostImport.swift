import Foundation

/// Servers from other SSH apps: `~/.ssh/config`, CSV exports (Termius, spreadsheets, …) and private key files, which
/// are matched to hosts by their IdentityFile name. Keys stay on the device (the app stores them in the Keychain).
public enum HostImport {
    public struct Candidate: Sendable, Hashable, Identifiable {
        public var name: String
        public var host: String
        public var port: Int
        public var user: String
        /// The IdentityFile's file name (`id_ed25519`), if the source named one.
        public var identityFile: String?
        /// ProxyJump: the jump host's alias or `user@host:port` (the first hop of a chain).
        public var proxyJump: String?
        public var id: String { "\(user)@\(host):\(port)#\(name)" }
        public init(name: String, host: String, port: Int = 22, user: String, identityFile: String? = nil, proxyJump: String? = nil) {
            self.name = name; self.host = host; self.port = port; self.user = user; self.identityFile = identityFile
            self.proxyJump = proxyJump
        }
    }

    /// Host blocks of an OpenSSH client config. Wildcard patterns (`Host *`, `*.example.com`) are defaults, not hosts;
    /// their User/Port apply to the hosts below them that don't set their own (as ssh does for `Host *` at the end).
    public static func parseSSHConfig(_ text: String, defaultUser: String = "root") -> [Candidate] {
        struct Block { var names: [String]; var opts: [String: String] = [:] }
        var blocks: [Block] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased(), value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
            if key == "host" {
                blocks.append(Block(names: value.split(separator: " ").map(String.init)))
            } else if key == "match" {
                blocks.append(Block(names: []))                       // Match blocks aren't hosts
            } else if !blocks.isEmpty, blocks[blocks.count - 1].opts[key] == nil {
                blocks[blocks.count - 1].opts[key] = value            // first value wins, like ssh
            }
        }
        let wildcard = blocks.filter { $0.names.contains { $0.contains("*") || $0.contains("?") } }
        func fallback(_ key: String) -> String? { wildcard.lazy.compactMap { $0.opts[key] }.first }
        var out: [Candidate] = []
        for b in blocks {
            for name in b.names where !name.contains("*") && !name.contains("?") && !name.hasPrefix("!") {
                let host = b.opts["hostname"] ?? name
                let user = b.opts["user"] ?? fallback("user") ?? defaultUser
                let port = Int(b.opts["port"] ?? fallback("port") ?? "22") ?? 22
                let identity = (b.opts["identityfile"] ?? fallback("identityfile")).map { ($0 as NSString).lastPathComponent }
                let jump = (b.opts["proxyjump"] ?? fallback("proxyjump"))?.split(separator: ",").first.map(String.init)
                    .flatMap { $0.lowercased() == "none" ? nil : $0 }
                out.append(Candidate(name: name, host: host, port: port, user: user, identityFile: identity, proxyJump: jump))
            }
        }
        return out
    }

    /// CSV with a header naming the columns (label/name, host/hostname/address/ip, port, user/username). Quotes and
    /// `;` separators are handled.
    public static func parseCSV(_ text: String, defaultUser: String = "root") -> [Candidate] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first else { return [] }
        let sep: Character = header.filter { $0 == ";" }.count > header.filter { $0 == "," }.count ? ";" : ","
        func cells(_ l: String) -> [String] {
            var out: [String] = [], cur = "", quoted = false
            for c in l {
                if c == "\"" { quoted.toggle() } else if c == sep && !quoted { out.append(cur); cur = "" } else { cur.append(c) }
            }
            out.append(cur)
            return out.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let cols = cells(header).map { $0.lowercased() }
        func index(_ names: [String]) -> Int? { cols.firstIndex { names.contains($0) } }
        guard let hostCol = index(["host", "hostname", "address", "ip", "server"]) else { return [] }
        let nameCol = index(["label", "name", "alias", "title"]), portCol = index(["port"]), userCol = index(["user", "username", "login"])
        return lines.dropFirst().compactMap { l in
            let c = cells(l)
            guard hostCol < c.count, !c[hostCol].isEmpty else { return nil }
            func at(_ i: Int?) -> String? { i.flatMap { $0 < c.count && !c[$0].isEmpty ? c[$0] : nil } }
            return Candidate(name: at(nameCol) ?? c[hostCol], host: c[hostCol], port: Int(at(portCol) ?? "") ?? 22,
                             user: at(userCol) ?? defaultUser)
        }
    }

    /// Whatever the text is: an OpenSSH config, or a CSV.
    public static func parse(_ text: String) -> [Candidate] {
        let lower = text.lowercased()
        if lower.range(of: #"(^|\n)\s*host\s+\S"#, options: .regularExpression) != nil { return parseSSHConfig(text) }
        return parseCSV(text)
    }

    /// An OpenSSH / PEM private key (not a public key, not a config).
    public static func isPrivateKey(_ text: String) -> Bool {
        text.contains("-----BEGIN") && text.contains("PRIVATE KEY-----")
    }

    /// The same server already exists (host case-insensitive, same port and user).
    public static func isDuplicate(_ c: Candidate, of existing: [(host: String, port: Int, user: String)]) -> Bool {
        existing.contains { $0.host.lowercased() == c.host.lowercased() && $0.port == c.port && $0.user == c.user }
    }

    /// Which of `servers` a ProxyJump value means: an alias (server name) or `[user@]host[:port]`.
    public static func jumpTarget(_ proxyJump: String, among servers: [(name: String, host: String, port: Int, user: String)]) -> Int? {
        if let i = servers.firstIndex(where: { $0.name == proxyJump }) { return i }
        var rest = Substring(proxyJump)
        var user: String?
        if let at = rest.lastIndex(of: "@") { user = String(rest[..<at]); rest = rest[rest.index(after: at)...] }
        var port = 22
        if let colon = rest.lastIndex(of: ":"), let p = Int(rest[rest.index(after: colon)...]) { port = p; rest = rest[..<colon] }
        let host = String(rest)
        return servers.firstIndex { ($0.host == host || $0.name == host) && $0.port == port && (user == nil || $0.user == user) }
    }
}

/// Jump host chains: which servers go through which, and whether a choice would make a loop.
public enum JumpChain {
    /// The hops to reach `start` (nearest jump host first), or nil when the chain loops or is longer than `limit`.
    public static func hops(from start: UUID, jumpOf: (UUID) -> UUID?, limit: Int = 5) -> [UUID]? {
        var chain: [UUID] = []
        var current = jumpOf(start)
        while let c = current {
            if c == start || chain.contains(c) || chain.count >= limit { return nil }
            chain.append(c)
            current = jumpOf(c)
        }
        return chain
    }

    /// Whether `candidate` may be `server`'s jump host (no loop back to `server`).
    public static func allowed(_ candidate: UUID, for server: UUID, jumpOf: (UUID) -> UUID?) -> Bool {
        guard candidate != server else { return false }
        return hops(from: server, jumpOf: { $0 == server ? candidate : jumpOf($0) }) != nil
    }
}
