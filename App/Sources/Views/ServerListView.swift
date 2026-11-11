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
    @State private var agentSetupServer: Server?
    @AppStorage("home.agentCardDismissed") private var agentCardDismissed = false

    var body: some View {
        List {
            if !settings.isConfigured && !AgentStatus.shared.anySignedIn(on: servers) && !agentCardDismissed, let first = servers.first {
                Section {
                    AgentSetupCard(
                        serverName: first.displayName,
                        usePlan: { agentSetupServer = first },
                        useKey: { showingSettings = true },
                        dismiss: { agentCardDismissed = true })
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
        .sheet(item: $agentSetupServer) { ServerToolsView(server: $0) { _ in } }
        .task {
            // Learn which agents are ready on each server (quietly, for the home screen).
            for server in servers { await AgentStatus.shared.refresh(server) }
        }
        .navigationDestination(item: $autoOpen) { ServerView(server: $0) }
        .sheet(item: Binding(get: { AppRouter.shared.pendingIncident }, set: { AppRouter.shared.pendingIncident = $0 })) { link in
            // A tapped uptime push: the incident for that check, over whatever is on screen.
            if let server = servers.first(where: { $0.id == link.server }) {
                NavigationStack {
                    IncidentView(server: server, checkID: link.check)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { AppRouter.shared.pendingIncident = nil } } }
                }
            } else {
                ContentUnavailableView("Server not found", systemImage: "server.rack", description: Text("This alert is for a server that isn't in Deckhand anymore."))
            }
        }
        .onChange(of: AppRouter.shared.pendingThread, initial: true) { _, id in
            // A notification or link for a chat: open its server; the server screen opens the chat.
            guard let id, let thread = try? context.fetch(FetchDescriptor<ChatThread>(predicate: #Predicate { $0.id == id })).first,
                  let server = thread.server else { return }
            if autoOpen?.id != server.id { autoOpen = server }
        }
        #if DEBUG
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            // After DECKHAND_RESET the query can lag behind the seeded insert: wait for the server.
            for _ in 0..<20 where DebugSeed.pendingRun != nil && servers.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
            }
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
                HStack(spacing: 6) {
                    Text(server.displayName).font(.body.weight(.semibold))
                    // Agents signed in on this server.
                    ForEach(AgentStatus.shared.clis(for: server), id: \.self) { BrandIcon(brand: $0.brand, size: 18) }
                }
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
        case .connected: String(localized: "Online")
        case .connecting: String(localized: "Connecting")
        case .failed: String(localized: "Offline")
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

/// Shown until an agent is ready somewhere: the two ways to get one, in plain words.
struct AgentSetupCard: View {
    let serverName: String
    let usePlan: () -> Void
    let useKey: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up your agent").font(.headline)
                    Text("The agent does the work on your servers. Pick one way — you can add the other later.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Not now")
            }
            option(icons: [.claude, .codex], title: "Your Claude or ChatGPT plan",
                   detail: "Claude Code or Codex runs on \(serverName). Sign in once — no API key needed.",
                   action: usePlan, id: "agentCard.plan")
            option(icons: [], symbol: "key.fill", title: "Your own API key",
                   detail: "Anthropic, OpenAI, OpenRouter or a local model. The agent runs in the app.",
                   action: useKey, id: "agentCard.key")
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner + 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner + 4, style: .continuous).stroke(Theme.hairline))
    }

    private func option(icons: [Brand], symbol: String? = nil, title: LocalizedStringKey, detail: LocalizedStringKey,
                        action: @escaping () -> Void, id: String) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 40, height: 40).background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        HStack(spacing: -10) { ForEach(icons, id: \.self) { BrandIcon(brand: $0, size: 30) } }.frame(width: 40, height: 40)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(uiColor: .systemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
