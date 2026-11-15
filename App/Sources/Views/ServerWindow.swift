import SwiftData
import SwiftUI

/// A server in a window of its own (Mac, iPad), so two servers can sit side by side.
struct ServerWindow: View {
    let serverID: UUID?
    @Query private var servers: [Server]

    var body: some View {
        Group {
            if let server = servers.first(where: { $0.id == serverID }) {
                NavigationStack { ServerView(server: server) }
            } else {
                ContentUnavailableView("Server not found", systemImage: "server.rack",
                                       description: Text("It may have been removed in another window."))
            }
        }
        .hostKeyPrompt()
        .appLockCover()
    }
}

extension View {
    /// Covers this window while App Lock is locked. The lock screen itself lives in a window of the first scene;
    /// extra windows (Mac, iPad) would otherwise stay readable next to it.
    func appLockCover() -> some View {
        overlay {
            if AppLock.shared.isLocked {
                ZStack {
                    Rectangle().fill(.background)
                    Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                }
                .ignoresSafeArea()
                .accessibilityIdentifier("window.locked")
            }
        }
    }
}
