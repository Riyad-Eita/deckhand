import DeckhandCore
import DeckhandSSH
import Foundation
import Observation
import SwiftData

/// Keeps one live SSH connection per server and handles first-connect host key trust.
@MainActor
@Observable
final class Connections {
    static let shared = Connections()

    struct HostKeyPrompt: Identifiable {
        let id = UUID()
        let serverName: String
        let fingerprint: String
        let respond: (Bool) -> Void
    }

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private var connections: [UUID: SSHConnection] = [:]
    private(set) var states: [UUID: State] = [:]
    /// Shown as an alert by the root view.
    var hostKeyPrompt: HostKeyPrompt?

    func state(for server: Server) -> State { states[server.id] ?? .idle }

    static func credential(for server: Server) -> SSHCredential? {
        guard let secret = Keychain.get(server.secretAccount) else { return nil }
        switch server.authKind {
        case .password: return .password(secret)
        case .key: return .privateKey(secret, passphrase: Keychain.get(server.secretAccount + ".passphrase"))
        }
    }

    /// Returns a connected `SSHConnection`, connecting (and asking about the host key) if needed.
    func connection(for server: Server) async throws -> SSHConnection {
        if let existing = connections[server.id], await existing.isConnected { return existing }
        guard let credential = Self.credential(for: server) else {
            throw SSHError.unsupportedKey("No password or key saved for this server.")
        }
        let connection = SSHConnection(
            endpoint: SSHEndpoint(host: server.host, port: server.port, username: server.username),
            credential: credential)
        states[server.id] = .connecting
        let name = server.displayName
        do {
            try await connection.connect(pinnedHostKey: server.pinnedHostKey) { [weak self] _, fingerprint in
                await self?.askToTrust(serverName: name, fingerprint: fingerprint) ?? false
            }
        } catch {
            states[server.id] = .failed(error.localizedDescription)
            throw error
        }
        if server.pinnedHostKey == nil, let key = await connection.hostKey { server.pinnedHostKey = key }
        server.lastConnectedAt = Date()
        connections[server.id] = connection
        states[server.id] = .connected
        return connection
    }

    func disconnect(_ server: Server) async {
        await connections[server.id]?.disconnect()
        connections[server.id] = nil
        states[server.id] = .idle
    }

    private func askToTrust(serverName: String, fingerprint: String) async -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DECKHAND_SEED_TRUST"] == "1" { return true }
        #endif
        return await withCheckedContinuation { continuation in
            hostKeyPrompt = HostKeyPrompt(serverName: serverName, fingerprint: fingerprint) { [weak self] trusted in
                self?.hostKeyPrompt = nil
                continuation.resume(returning: trusted)
            }
        }
    }
}
