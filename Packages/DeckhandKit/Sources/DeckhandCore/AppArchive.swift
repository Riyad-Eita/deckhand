import CommonCrypto
import CryptoKit
import Foundation

/// Everything to move Deckhand to a new phone: servers, connections, settings and — only if chosen — the secrets.
/// Sealed with AES-GCM under a key derived from a passphrase (PBKDF2-SHA256).
public struct AppArchive: Codable, Sendable, Equatable {
    public struct ServerItem: Codable, Sendable, Equatable {
        public var id: UUID
        public var name: String
        public var host: String
        public var port: Int
        public var username: String
        public var authKind: String
        public var pinnedHostKey: String?
        public var workingDirectory: String
        public var recentDirectories: [String]
        public init(id: UUID, name: String, host: String, port: Int, username: String, authKind: String, pinnedHostKey: String?,
                    workingDirectory: String, recentDirectories: [String]) {
            self.id = id; self.name = name; self.host = host; self.port = port; self.username = username; self.authKind = authKind
            self.pinnedHostKey = pinnedHostKey; self.workingDirectory = workingDirectory; self.recentDirectories = recentDirectories
        }
    }

    public struct ConnectionItem: Codable, Sendable, Equatable {
        public var id: UUID
        public var name: String
        public var kind: String
        public var url: String
        public var command: String
        public var enabled: Bool
        public init(id: UUID, name: String, kind: String, url: String, command: String, enabled: Bool) {
            self.id = id; self.name = name; self.kind = kind; self.url = url; self.command = command; self.enabled = enabled
        }
    }

    public var version = 1
    public var created: Date
    public var servers: [ServerItem]
    public var connections: [ConnectionItem]
    /// App settings (UserDefaults values).
    public var settings: [String: JSONValue]
    /// Keychain items by account; empty unless the user chose to include secrets.
    public var secrets: [String: String]

    public init(created: Date = Date(), servers: [ServerItem], connections: [ConnectionItem], settings: [String: JSONValue], secrets: [String: String]) {
        self.created = created; self.servers = servers; self.connections = connections; self.settings = settings; self.secrets = secrets
    }

    public enum ArchiveError: LocalizedError, Equatable {
        case notAnArchive, wrongPassphrase, newerVersion
        public var errorDescription: String? {
            switch self {
            case .notAnArchive: String(localized: "This isn't a Deckhand backup file.")
            case .wrongPassphrase: String(localized: "Wrong passphrase, or the file is damaged.")
            case .newerVersion: String(localized: "This backup comes from a newer Deckhand. Update the app first.")
            }
        }
    }

    static let magic = Data("DHBK1".utf8)
    static let iterations: UInt32 = 210_000

    static func key(_ passphrase: String, salt: Data, iterations: UInt32) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(passphrase.utf8)
        salt.withUnsafeBytes { s in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &out, out.count)
        }
        return SymmetricKey(data: out)
    }

    /// `DHBK1` · 16-byte salt · iterations (UInt32, big endian) · AES-GCM combined (nonce, ciphertext, tag).
    public func sealed(passphrase: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plain = try encoder.encode(self)
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let box = try AES.GCM.seal(plain, using: Self.key(passphrase, salt: salt, iterations: Self.iterations))
        var it = Self.iterations.bigEndian
        return Self.magic + salt + Data(bytes: &it, count: 4) + box.combined!
    }

    public static func open(_ data: Data, passphrase: String) throws -> AppArchive {
        guard data.count > magic.count + 20 + 28, data.prefix(magic.count) == magic else { throw ArchiveError.notAnArchive }
        let salt = data.subdata(in: magic.count..<magic.count + 16)
        let itData = data.subdata(in: magic.count + 16..<magic.count + 20)
        let iterations = itData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        guard iterations >= 10_000, iterations <= 10_000_000 else { throw ArchiveError.notAnArchive }
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(combined: data.subdata(in: magic.count + 20..<data.count))
            plain = try AES.GCM.open(box, using: key(passphrase, salt: salt, iterations: iterations))
        } catch { throw ArchiveError.wrongPassphrase }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(AppArchive.self, from: plain)
        guard archive.version <= 1 else { throw ArchiveError.newerVersion }
        return archive
    }
}
