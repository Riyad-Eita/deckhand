import Foundation

/// Connecting a server by scanning a QR code, with nothing to copy: `scripts/pair.sh` on the server makes a one-time
/// key that may only hand over one public key (forced command, `restrict`, 15 minutes) and shows
/// `deckhand://pair?h=&p=&u=&n=&k=&f=&e=` as a QR code. The app connects with that key, checks the host key against
/// the fingerprints in the code, sends its own new public key and from then on signs in with it.
public enum Pairing {
    /// The line to run on the server.
    public static let command = "curl -fsSL https://raw.githubusercontent.com/Riyad-Eita/deckhand/main/scripts/pair.sh | sh"

    public struct Code: Sendable, Hashable {
        public var host: String
        public var port: Int
        public var user: String
        public var name: String
        /// The one-time key's 32-byte Ed25519 seed.
        public var seed: Data
        /// The server's host key fingerprints (`SHA256:…`), as printed by `ssh-keygen -l`.
        public var fingerprints: [String]
        public var expires: Date

        public init(host: String, port: Int, user: String, name: String, seed: Data, fingerprints: [String], expires: Date) {
            self.host = host; self.port = port; self.user = user; self.name = name
            self.seed = seed; self.fingerprints = fingerprints; self.expires = expires
        }

        public func isExpired(now: Date = Date()) -> Bool { now >= expires }
    }

    /// A pairing code from its link; nil when it isn't one or a field is unsafe.
    public static func parse(_ url: URL) -> Code? {
        guard url.scheme?.lowercased() == "deckhand", url.host == "pair" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            let v = items.first(where: { $0.name == name })?.value?.trimmingCharacters(in: .whitespaces) ?? ""
            return v.isEmpty ? nil : v
        }
        guard let host = value("h"), HostLink.isHost(host),
              let user = value("u"), HostLink.isUser(user),
              let port = Int(value("p") ?? "22"), (1...65535).contains(port),
              let seed = value("k").flatMap(base64URL), seed.count == 32,
              let expires = value("e").flatMap(Double.init) else { return nil }
        let fingerprints = (value("f") ?? "").split(separator: ",").map { String($0) }
            .filter { $0.range(of: #"^[A-Za-z0-9+/]{43}$"#, options: .regularExpression) != nil }
            .map { "SHA256:" + $0 }
        guard !fingerprints.isEmpty else { return nil }
        return Code(host: host, port: port, user: user, name: HostLink.cleanName(value("n") ?? host), seed: seed,
                    fingerprints: fingerprints, expires: Date(timeIntervalSince1970: expires))
    }

    static func base64URL(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    /// What the forced command answers.
    public enum Answer: Equatable, Sendable {
        case paired, expired, badKey, other(String)
        public init(_ output: String) {
            let t = output.trimmingCharacters(in: .whitespacesAndNewlines)
            switch t.split(separator: "\n").last.map(String.init) ?? "" {
            case "@@paired": self = .paired
            case "@@expired": self = .expired
            case "@@badkey": self = .badKey
            default: self = .other(t)
            }
        }
    }
}
