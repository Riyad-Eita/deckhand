@preconcurrency import Citadel
import Crypto
import DeckhandCore
import Foundation

/// The app's half of pairing: sign in with the one-time key from the QR code, accept only the host key the code
/// names, hand over a fresh key made on this device, and return it for the server's saved login.
public enum PairingClient {
    public struct Result: Sendable {
        /// The device's new private key (OpenSSH text) — store it like any other server key.
        public let privateKey: String
        public let publicKey: String
        /// The server's host key line, to pin.
        public let hostKey: String
    }

    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case expired
        case wrongServer(String)
        case refused(String)

        public var errorDescription: String? {
            switch self {
            case .expired:
                String(localized: "This pairing code has expired or was already used. Run the line on the server again for a new one.")
            case .wrongServer(let f):
                String(localized: "The server at this address isn't the one that made the code (host key \(f)). Check the address; nothing was sent.")
            case .refused(let why):
                String(localized: "The server didn't take the key: \(why)")
            }
        }
    }

    /// `host` / `port` override the address in the code (the user corrected it).
    public static func pair(_ code: Pairing.Code, host: String? = nil, port: Int? = nil, deviceName: String) async throws -> Result {
        guard !code.isExpired() else { throw Failure.expired }
        let oneTime = try Curve25519.Signing.PrivateKey(rawRepresentation: code.seed)
        let connection = SSHConnection(
            endpoint: SSHEndpoint(host: host ?? code.host, port: port ?? code.port, username: code.user),
            credential: .privateKey(oneTime.makeSSHRepresentation(), passphrase: nil))
        let allowed = Set(code.fingerprints)
        do {
            try await connection.connect(pinnedHostKey: nil) { _, fingerprint in allowed.contains(fingerprint) }
        } catch SSHError.hostKeyRejected(let f) {
            throw Failure.wrongServer(f)
        } catch SSHError.signInRejected {
            throw Failure.expired
        }
        let (privateKey, publicKey) = SSHKeys.generateEd25519(comment: comment(for: deviceName))
        let output: CommandResult
        do {
            output = try await connection.runVerbatim(publicKey)
        } catch {
            await connection.disconnect()
            throw error
        }
        let hostKey = await connection.hostKey
        await connection.disconnect()
        switch Pairing.Answer(output.stdout) {
        case .paired:
            guard let hostKey else { throw Failure.refused("no host key") }
            return Result(privateKey: privateKey, publicKey: publicKey, hostKey: hostKey)
        case .expired: throw Failure.expired
        case .badKey: throw Failure.refused(String(localized: "the key was not in the expected form"))
        case .other(let text): throw Failure.refused(text.isEmpty ? (output.stderr.isEmpty ? "?" : output.stderr) : text)
        }
    }

    /// A one-time key for an invite: its 32-byte seed (goes into the QR code) and its `ssh-ed25519 AAAA…` line.
    public static func makeOneTimeKey() -> (seed: Data, publicKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        let line = SSHKeys.publicKeyLine(for: key, comment: "x")
        return (key.rawRepresentation, String(line.dropLast(2)))
    }

    /// `deckhand <device>` with only the characters the server's check accepts.
    static func comment(for deviceName: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._@()-")
        let clean = String(String.UnicodeScalarView(deviceName.unicodeScalars.filter { allowed.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        return String(("deckhand " + clean).prefix(60)).trimmingCharacters(in: .whitespaces)
    }
}
