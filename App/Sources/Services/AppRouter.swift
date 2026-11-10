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

    func handle(_ url: URL) {
        guard url.scheme == "deckhand", url.host == "thread", let id = UUID(uuidString: url.lastPathComponent) else { return }
        pendingThread = id
    }

    static func link(for thread: UUID) -> String { "deckhand://thread/\(thread.uuidString)" }
}
