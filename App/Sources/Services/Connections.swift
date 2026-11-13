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
    /// True while a sheet that can trigger connections is on screen; the sheet then shows the host key alert.
    var sheetOpen = false

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
        try await KeyProtection.shared.ensureUnlocked()
        guard let credential = Self.credential(for: server) else {
            throw SSHError.unsupportedKey("No password or key saved for this server.")
        }
        let via = try await jumpConnection(for: server)
        let connection = SSHConnection(
            endpoint: SSHEndpoint(host: server.host, port: server.port, username: server.username),
            credential: credential, via: via)
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

    struct JumpLoop: LocalizedError {
        let name: String
        var errorDescription: String? {
            String(localized: "The jump hosts of \(name) go round in a circle. Pick another one in the server's settings.")
        }
    }

    /// The connected jump host for `server`, if it uses one (chains work; loops are refused).
    func jumpConnection(for server: Server) async throws -> SSHConnection? {
        guard let jumpID = server.jumpHostID else { return nil }
        let all = (try? DeckhandApp.container.mainContext.fetch(FetchDescriptor<Server>())) ?? []
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        guard JumpChain.hops(from: server.id, jumpOf: { byID[$0]?.jumpHostID }) != nil else {
            throw JumpLoop(name: server.displayName)
        }
        guard let jump = byID[jumpID] else { return nil }
        return try await connection(for: jump)
    }

    /// Logs in on another port with the saved credentials; the host key must match the pinned one.
    func testLogin(_ server: Server, port: Int, username: String? = nil, credential: SSHCredential? = nil) async throws -> SSHConnection {
        if credential == nil { try await KeyProtection.shared.ensureUnlocked() }
        guard let credential = credential ?? Self.credential(for: server) else {
            throw SSHError.unsupportedKey("No password or key saved for this server.")
        }
        let via = try await jumpConnection(for: server)
        let connection = SSHConnection(
            endpoint: SSHEndpoint(host: server.host, port: port, username: username ?? server.username), credential: credential, via: via)
        let pinned = server.pinnedHostKey
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await connection.connect(pinnedHostKey: pinned) { _, _ in false } }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw CLIError("No answer on port \(port).")
            }
            try await group.next()
            group.cancelAll()
        }
        _ = try await connection.run("true", timeout: .seconds(10))
        return connection
    }

    /// Makes `connection` (on `port`) the server's connection and saves the new port.
    func adopt(_ connection: SSHConnection, for server: Server, port: Int) async {
        if let old = connections[server.id], old !== connection { await old.disconnect() }
        server.port = port
        connections[server.id] = connection
        states[server.id] = .connected
    }

    /// Pings every open connection; dead ones are dropped so the next use reconnects quietly.
    func checkConnections() async {
        for (id, connection) in connections {
            do {
                let r = try await connection.run("true", timeout: .seconds(10))
                if r.exitCode != 0 && r.exitCode != 124 { throw SSHError.notConnected }
            } catch {
                await connection.disconnect()
                connections[id] = nil
                states[id] = .idle
            }
        }
    }

    /// Runs `checkConnections` every 30 s while the app is active.
    func heartbeat() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            await checkConnections()
        }
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
