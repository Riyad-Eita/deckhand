import DeckhandCore
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

    /// A risky action waiting for approval (`deckhand://approve/<server>/<fingerprint>?who=…&cmd=…`).
    var pendingApproval: ApprovalLink?

    /// A server to open (`deckhand://server/<id>`, the status widget).
    var pendingServer: UUID?

    /// Servers from a `deckhand://add?…` link (or a scanned QR code), shown on the import screen — never added unseen.
    var pendingImport: ImportLink?

    struct ImportLink: Identifiable, Equatable {
        let candidates: [HostImport.Candidate]
        let id = UUID()
    }

    struct ApprovalLink: Identifiable, Equatable {
        let server: UUID
        let fingerprint: String
        let who: String
        let command: String
        var id: String { fingerprint }
    }

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
        case "approve":
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if parts.count == 2, let server = UUID(uuidString: parts[0]), parts[1].range(of: "^[0-9a-f]{12}$", options: .regularExpression) != nil {
                pendingApproval = ApprovalLink(server: server, fingerprint: parts[1],
                                               who: q.first { $0.name == "who" }?.value ?? "",
                                               command: q.first { $0.name == "cmd" }?.value ?? "")
            }
        case "server":
            if let id = UUID(uuidString: url.lastPathComponent) { pendingServer = id }
        case "add":
            if let c = HostLink.parse(url) { pendingImport = ImportLink(candidates: [c]) }
        case "uptime":
            if parts.count == 2, let server = UUID(uuidString: parts[0]) { pendingIncident = IncidentLink(server: server, check: parts[1]) }
        default:
            break
        }
    }

    static func link(for thread: UUID) -> String { "deckhand://thread/\(thread.uuidString)" }
}
