import DeckhandCore
import DeckhandSSH
import Foundation
import SwiftData

/// Models that live on one of the user's servers (`deckhand-server://…`) are reached through an SSH port forward,
/// opened when a request goes out and kept while that server's connection lives.
@MainActor
final class ServerTunnels {
    static let shared = ServerTunnels()

    enum Failure: LocalizedError {
        case serverGone
        var errorDescription: String? { String(localized: "The server this model runs on was removed from Deckhand. Pick another model in Settings.") }
    }

    private var forwards: [String: (connection: ObjectIdentifier, forward: PortForward)] = [:]

    /// The local address for `url`; other URLs come back unchanged.
    func resolve(_ url: URL) async throws -> URL {
        guard let p = ServerModelURL.parse(url) else { return url }
        let id = p.serverID
        guard let server = try DeckhandApp.container.mainContext.fetch(FetchDescriptor<Server>(predicate: #Predicate { $0.id == id })).first else {
            throw Failure.serverGone
        }
        let conn = try await Connections.shared.connection(for: server)
        let key = "\(id.uuidString):\(p.port)"
        if let existing = forwards[key], existing.connection == ObjectIdentifier(conn) {
            return ServerModelURL.local(port: existing.forward.localPort, path: p.path)
        }
        forwards[key]?.forward.stop()
        let forward = try await conn.forward(remotePort: p.port)
        forwards[key] = (ObjectIdentifier(conn), forward)
        return ServerModelURL.local(port: forward.localPort, path: p.path)
    }

    /// The server's name for a `deckhand-server://` address, for Settings.
    static func serverName(for url: URL) -> String? {
        guard let p = ServerModelURL.parse(url) else { return nil }
        let id = p.serverID
        return (try? DeckhandApp.container.mainContext.fetch(FetchDescriptor<Server>(predicate: #Predicate { $0.id == id })).first)?.displayName
    }
}

/// A provider whose address is resolved (tunnelled) right before each request.
struct TunneledProvider: LLMProvider {
    let config: ProviderConfig

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var resolved = config
                    resolved.baseURL = try await ServerTunnels.shared.resolve(config.baseURL)
                    for try await event in Providers.make(resolved).stream(request) { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum AppProviders {
    /// Like `Providers.make`, but models on the user's servers go through an SSH tunnel.
    static func make(_ config: ProviderConfig) -> any LLMProvider {
        ServerModelURL.parse(config.baseURL) != nil ? TunneledProvider(config: config) : Providers.make(config)
    }
}
