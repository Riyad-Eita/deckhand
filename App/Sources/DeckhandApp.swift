import SwiftData
import SwiftUI

@main
struct DeckhandApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppSettings.shared)
                .environment(Connections.shared)
        }
        .modelContainer(for: [Server.self, ChatThread.self, ConnectionRecord.self])
    }
}

struct RootView: View {
    @Environment(Connections.self) private var connections
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context

    var body: some View {
        @Bindable var connections = connections
        NavigationStack {
            ServerListView()
        }
        .hostKeyPrompt()
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await connections.checkConnections()
            await connections.heartbeat()
        }
        #if DEBUG
        .onAppear { DebugSeed.apply(context) }
        #endif
    }
}

/// Shows the first-connect host key question. Attach it to the root and to every sheet, because an alert
/// on a view that is covered by a sheet cannot appear.
struct HostKeyPromptModifier: ViewModifier {
    @Environment(Connections.self) private var connections
    @Environment(\.isPresented) private var isPresented
    let inSheet: Bool

    func body(content: Content) -> some View {
        content.alert(
            "Trust this server?",
            isPresented: Binding(
                get: { connections.hostKeyPrompt != nil && (inSheet || !connections.sheetOpen) },
                set: { if !$0 { connections.hostKeyPrompt?.respond(false) } }),
            presenting: connections.hostKeyPrompt
        ) { prompt in
            Button("Trust") { prompt.respond(true) }
            Button("Cancel", role: .cancel) { prompt.respond(false) }
        } message: { prompt in
            Text("First connection to \(prompt.serverName). Its host key fingerprint is\n\(prompt.fingerprint)\n\nDeckhand remembers it and warns you if it ever changes.")
        }
        .onAppear { if inSheet { connections.sheetOpen = true } }
        .onDisappear { if inSheet { connections.sheetOpen = false } }
    }
}

extension View {
    func hostKeyPrompt(inSheet: Bool = false) -> some View { modifier(HostKeyPromptModifier(inSheet: inSheet)) }
}
