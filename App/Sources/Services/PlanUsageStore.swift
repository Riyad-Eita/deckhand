import DeckhandCore
import Foundation
import Observation

/// What the server CLIs report about the Claude and ChatGPT plans, per server (read on demand, kept briefly).
@MainActor
@Observable
final class PlanUsageStore {
    static let shared = PlanUsageStore()
    private(set) var usage: [UUID: [ServerCLI: PlanUsage.Usage]] = [:]
    private var loaded: [UUID: Date] = [:]

    func usage(_ cli: ServerCLI, on server: Server) -> PlanUsage.Usage? { usage[server.id]?[cli] }

    /// Reads it again unless that happened within `maxAge`.
    func refresh(_ server: Server, maxAge: TimeInterval = 120) async {
        if let at = loaded[server.id], Date().timeIntervalSince(at) < maxAge { return }
        guard let conn = try? await Connections.shared.connection(for: server),
              let out = try? await conn.run(PlanUsage.statusCommand, timeout: .seconds(20)).stdout else { return }
        usage[server.id] = Dictionary(PlanUsage.parse(out).map { ($0.cli, $0) }, uniquingKeysWith: { a, _ in a })
        loaded[server.id] = Date()
    }
}
