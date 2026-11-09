import SwiftData
import SwiftUI

struct ServerListView: View {
    @Environment(\.modelContext) private var context
    @Environment(Connections.self) private var connections
    @Environment(AppSettings.self) private var settings
    @Query(sort: \Server.createdAt) private var servers: [Server]
    @State private var editing: Server?
    @State private var addingServer = false
    @State private var showingSettings = false

    var body: some View {
        List {
            if !settings.isConfigured {
                Section {
                    Button { showingSettings = true } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connect a model").font(.headline)
                                Text("Add your Claude, OpenAI or OpenRouter key — or use Claude Code and Codex on your server.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "key.horizontal") }
                    }
                }
            }
            Section(servers.isEmpty ? "" : "Servers") {
                ForEach(servers) { server in
                    NavigationLink(value: server) {
                        ServerRow(server: server, state: connections.state(for: server))
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { delete(server) }
                        Button("Edit") { editing = server }.tint(.gray)
                    }
                }
            }
        }
        .overlay {
            if servers.isEmpty {
                ContentUnavailableView {
                    Label("No servers yet", systemImage: "server.rack")
                } description: {
                    Text("Add a Linux server you can reach over SSH. Deckhand can create a key for it.")
                } actions: {
                    Button("Add Server") { addingServer = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Deckhand")
        .navigationDestination(for: Server.self) { ServerView(server: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { addingServer = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Server")
            }
        }
        .sheet(isPresented: $addingServer) { ServerEditorView(server: nil) }
        .sheet(item: $editing) { ServerEditorView(server: $0) }
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }

    private func delete(_ server: Server) {
        Task { await connections.disconnect(server) }
        Keychain.set(nil, for: server.secretAccount)
        Keychain.set(nil, for: server.secretAccount + ".passphrase")
        context.delete(server)
    }
}

struct ServerRow: View {
    let server: Server
    let state: Connections.State

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName).font(.headline)
                Text(server.address).font(Theme.monoSmall).foregroundStyle(.secondary)
            }
            Spacer()
            StatusDot(state: state)
        }
        .padding(.vertical, 4)
    }
}
