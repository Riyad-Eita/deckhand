import Foundation
import Observation

/// Opens a chat from outside: a tapped notification or a `deckhand://thread/<id>` link.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()
    /// The chat to open; cleared by the screen that opened it.
    var pendingThread: UUID?
    /// The chat on screen right now (no notification for it).
    var visibleThread: UUID?

    /// A failing uptime check to open (`deckhand://uptime/<server>/<check>`, the link in an uptime push).
    var pendingIncident: IncidentLink?

    struct IncidentLink: Identifiable, Equatable {
        let server: UUID
        let check: String
        var id: String { server.uuidString + check }
    }

    func handle(_ url: URL) {
        guard url.scheme == "deckhand" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host {
        case "thread":
            if let id = UUID(uuidString: url.lastPathComponent) { pendingThread = id }
        case "uptime":
            if parts.count == 2, let server = UUID(uuidString: parts[0]) { pendingIncident = IncidentLink(server: server, check: parts[1]) }
        default:
            break
        }
    }

    static func link(for thread: UUID) -> String { "deckhand://thread/\(thread.uuidString)" }
}
