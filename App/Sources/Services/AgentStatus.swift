import DeckhandCore
import Foundation
import Observation

/// Which CLIs are signed in on which server, as last seen — so the home screen can show it without asking.
@MainActor
@Observable
final class AgentStatus {
    static let shared = AgentStatus()
    private(set) var signedIn: [UUID: Set<ServerCLI>] = [:]
    private let key = "agents.signedIn"

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        for (id, clis) in stored {
            if let uuid = UUID(uuidString: id) { signedIn[uuid] = Set(clis.compactMap(ServerCLI.init(rawValue:))) }
        }
    }

    func update(_ server: Server, from inventory: ServerInventory) {
        signedIn[server.id] = Set(ServerCLI.allCases.filter { inventory.state(for: $0).loggedIn })
        save()
    }

    /// nil while the server hasn't been asked yet.
    func isSignedIn(_ cli: ServerCLI, on server: Server) -> Bool? { signedIn[server.id].map { $0.contains(cli) } }

    func clis(for server: Server) -> [ServerCLI] { ServerCLI.allCases.filter { signedIn[server.id]?.contains($0) == true } }
    /// Whether any of these servers has a signed-in CLI (servers deleted since don't count).
    func anySignedIn(on servers: [Server]) -> Bool { servers.contains { !(signedIn[$0.id] ?? []).isEmpty } }

    /// Asks a server quietly (used when the home screen appears).
    func refresh(_ server: Server) async {
        guard let conn = try? await Connections.shared.connection(for: server),
              let r = try? await conn.run(ServerInventory.probeCommand, timeout: .seconds(40)) else { return }
        update(server, from: ServerInventory.parse(r.stdout))
    }

    private func save() {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: signedIn.map { ($0.key.uuidString, $0.value.map(\.rawValue)) }), forKey: key)
    }
}
