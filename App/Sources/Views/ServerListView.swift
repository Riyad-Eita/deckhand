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
    @State private var autoOpen: Server?
    @State private var showingConnections = false

    var body: some View {
        List {
            if !settings.isConfigured && !servers.isEmpty {
                Section {
                    WorksWithCard { showingSettings = true }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
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
                VStack(spacing: 22) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 84, height: 84)
                        .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    VStack(spacing: 8) {
                        Text("Add your first server").font(.title2.weight(.semibold))
                        Text("Any Linux machine you can reach over SSH. Deckhand can create a secure key for it on this iPhone.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Button { addingServer = true } label: {
                        Text("Add Server").font(.headline).frame(maxWidth: 260).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    WorksWithStrip().padding(.top, 8)
                }
                .padding(32)
            }
        }
        .navigationTitle("Deckhand")
        .safeAreaInset(edge: .bottom) {
            if !servers.isEmpty {
                Text("Beta — new features arrive with every update.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
        .navigationDestination(for: Server.self) { ServerView(server: $0) }
        .navigationDestination(item: $autoOpen) { ServerView(server: $0) }
        #if DEBUG
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            if DebugSeed.pendingRun != nil { autoOpen = servers.first }
            if ProcessInfo.processInfo.environment["DECKHAND_SEED_SCREEN"] == "connections" { showingConnections = true }
        }
        .sheet(isPresented: $showingConnections) { NavigationStack { ConnectionsView() } }
        #endif
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
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    LinearGradient(colors: [Color(white: 0.28), Color(white: 0.14)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(server.displayName).font(.body.weight(.semibold))
                Text(server.address).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                StatusDot(state: state)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch state {
        case .connected: "Online"
        case .connecting: "Connecting"
        case .failed: "Offline"
        case .idle: ""
        }
    }
}

/// Logos of everything Deckhand works with.
struct WorksWithStrip: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("WORKS WITH").font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                ForEach([Brand.claude, .codex, .openai, .openrouter, .github, .mcp], id: \.self) { BrandIcon(brand: $0, size: 34) }
            }
        }
    }
}

/// Shown until a model or engine is set up.
struct WorksWithCard: View {
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: -6) {
                ForEach([Brand.claude, .codex, .openai, .openrouter], id: \.self) { BrandIcon(brand: $0, size: 32) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Bring an agent").font(.headline)
                Text("Use your Claude or ChatGPT plan through Claude Code and Codex on your server — or add an API key.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button(action: action) {
                Text("Set Up").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner + 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner + 4, style: .continuous).stroke(Theme.hairline))
    }
}
