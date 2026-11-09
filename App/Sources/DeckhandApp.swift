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
    @Environment(\.modelContext) private var context

    var body: some View {
        @Bindable var connections = connections
        NavigationStack {
            ServerListView()
        }
        .alert(
            "Trust this server?",
            isPresented: Binding(
                get: { connections.hostKeyPrompt != nil },
                set: { if !$0 { connections.hostKeyPrompt?.respond(false) } }),
            presenting: connections.hostKeyPrompt
        ) { prompt in
            Button("Trust", role: nil) { prompt.respond(true) }
            Button("Cancel", role: .cancel) { prompt.respond(false) }
        } message: { prompt in
            Text("First connection to \(prompt.serverName). Its host key fingerprint is\n\(prompt.fingerprint)\n\nDeckhand remembers it and warns you if it ever changes.")
        }
        #if DEBUG
        .onAppear { DebugSeed.apply(context) }
        #endif
    }
}
