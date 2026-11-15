import SwiftData
import SwiftUI

/// A server in a window of its own (Mac, iPad), so two servers can sit side by side.
struct ServerWindow: View {
    let serverID: UUID?
    @Query private var servers: [Server]
    @Environment(\.openWindow) private var openWindow
    @State private var scene: UIWindowScene?

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
        .background(SceneReader(scene: $scene))
        #if DEBUG
        .task(id: scene) {
            // UI tests start fresh, but the system restores the windows of the last run: close a server window that
            // came back with the launch and bring the main window up.
            guard ProcessInfo.processInfo.environment["DECKHAND_RESET"] == "1", let scene,
                  Date().timeIntervalSince(DeckhandApp.launchedAt) < 5 else { return }
            openWindow(id: "main")
            UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
        }
        #endif
    }
}

/// The window scene a view lives in.
private struct SceneReader: UIViewRepresentable {
    @Binding var scene: UIWindowScene?
    func makeUIView(context: Context) -> Probe { Probe { scene = $0 } }
    func updateUIView(_ uiView: Probe, context: Context) {}

    final class Probe: UIView {
        let found: (UIWindowScene?) -> Void
        init(found: @escaping (UIWindowScene?) -> Void) { self.found = found; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            let s = window?.windowScene
            DispatchQueue.main.async { self.found(s) }
        }
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
