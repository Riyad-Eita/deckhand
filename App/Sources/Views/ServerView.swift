import DeckhandCore
import SwiftData
import SwiftUI

struct ServerView: View {
    let server: Server

    enum Tab: String, CaseIterable, Identifiable {
        case agent = "Agent"
        case server = "Server"
        case terminal = "Terminal"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .agent
    @State private var showingTools = false
    /// Engine + prompt for a task the agent tab should open right away.
    @State private var startTask: StartTask?
    /// A command for the terminal to run once it is connected (e.g. a CLI login).
    @State private var terminalCommand: String?
    @Environment(Connections.self) private var connections

    init(server: Server) {
        self.server = server
        #if DEBUG
        if DebugSeed.pendingRun?.engine == "server" { _tab = State(initialValue: .server) }
        if let run = DebugSeed.pendingRun, run.engine == "terminal" {
            _tab = State(initialValue: .terminal)
            if !run.prompt.isEmpty { _terminalCommand = State(initialValue: run.prompt) }
        }
        #endif
    }

    var body: some View {
        Group {
            switch tab {
            case .agent: ThreadListView(server: server, startTask: $startTask)
            case .server:
                ServerDashboardView(
                    server: server,
                    runInTerminal: { command in
                        terminalCommand = command
                        tab = .terminal
                    })
            case .terminal: TerminalScreen(server: server, pendingCommand: $terminalCommand)
            }
        }
        .navigationTitle(server.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingTools = true } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "wrench.and.screwdriver")
                        StatusDot(state: connections.state(for: server)).offset(x: 4, y: -3)
                    }
                }
                .accessibilityLabel("Server Tools")
            }
        }
        .onChange(of: showingTools) { _, showing in
            if showing {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .onChange(of: AppRouter.shared.pendingThread, initial: true) { _, id in
            if let id, server.threads?.contains(where: { $0.id == id }) == true { tab = .agent }
        }
        .sheet(isPresented: $showingTools) {
            ServerToolsView(server: server) { command in
                terminalCommand = command
                tab = .terminal
            }
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.environment["DECKHAND_SEED_TOOLS"] == "1" {
                try? await Task.sleep(for: .seconds(3))
                showingTools = true
            }
        }
        #endif
    }
}

struct StartTask: Equatable {
    let engine: Engine
    let prompt: String
}

struct ThreadListView: View {
    let server: Server
    @Binding var startTask: StartTask?
    @Environment(\.modelContext) private var context
    @State private var openThread: ChatThread?
    @State private var pickingFolderFor: Engine?
    @State private var signingIn: ServerCLI?
    @State private var showingSettings = false

    private func isReady(_ engine: Engine) -> Bool {
        if let cli = engine.serverCLI { return AgentStatus.shared.isSignedIn(cli, on: server) != false }
        return AppSettings.shared.isConfigured
    }

    private var threads: [ChatThread] {
        (server.threads ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        List {
            Section {
                ForEach([Engine.claudeCode, .codex, .ownKey]) { engine in
                    Button {
                        // Not ready yet: sign in (or add a key) first instead of starting a task that fails.
                        if let cli = engine.serverCLI, AgentStatus.shared.isSignedIn(cli, on: server) == false {
                            signingIn = cli
                        } else if engine == .ownKey && !AppSettings.shared.isConfigured {
                            showingSettings = true
                        } else {
                            pickingFolderFor = engine
                        }
                    } label: { EngineRow(engine: engine, ready: isReady(engine)) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("engine.\(engine.rawValue)")
                }
            } header: {
                Text("Start a task with")
            }
            Section {
                NavigationLink { ServerMemoryView(server: server) } label: {
                    Label("Server notes", systemImage: "note.text")
                }
                .accessibilityIdentifier("agent.memory")
            } footer: {
                Text("What the agents remember about this server.")
            }
            if !threads.isEmpty {
                Section("Recent") {
                    ForEach(threads) { thread in
                        Button { openThread = thread } label: {
                            HStack(spacing: 12) {
                                BrandIcon(brand: thread.engine.brand, size: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(thread.title).font(.body).foregroundStyle(.primary).lineLimit(1)
                                    HStack(spacing: 4) {
                                        Text(thread.engine.shortTitle)
                                        Text("·")
                                        Text(thread.workingDirectory).lineLimit(1).truncationMode(.head)
                                        Text("·")
                                        Text(thread.updatedAt, format: .relative(presentation: .named))
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if thread.cliRunActive {
                                    Text("Running").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(Theme.accent.opacity(0.13), in: Capsule())
                                }
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for i in offsets { context.delete(threads[i]) }
                    }
                }
            }
        }
        .navigationDestination(item: $openThread) { AgentChatView(thread: $0, server: server) }
        .task { await AgentStatus.shared.refresh(server) }
        .sheet(item: $signingIn) { cli in CLILoginView(server: server, cli: cli) }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .onChange(of: AppRouter.shared.pendingThread, initial: true) { _, id in
            guard let id, let thread = threads.first(where: { $0.id == id }) else { return }
            AppRouter.shared.pendingThread = nil
            openThread = thread
        }
        .task(id: startTask) {
            guard let start = startTask else { return }
            startTask = nil
            let thread = ChatThread(server: server, workingDirectory: server.recentDirectories.first ?? server.workingDirectory, engine: start.engine)
            context.insert(thread)
            PendingPrompt.set(start.prompt, for: thread.id)
            openThread = thread
        }
        .sheet(item: $pickingFolderFor) { engine in
            FolderPicker(server: server, engine: engine) { folder in
                let thread = ChatThread(server: server, workingDirectory: folder, engine: engine)
                context.insert(thread)
                openThread = thread
            }
        }
        #if DEBUG
        .task {
            if let e = ProcessInfo.processInfo.environment["DECKHAND_SEED_PICK"], let engine = Engine(rawValue: e) {
                pickingFolderFor = engine
            }
        }
        .task {
            // "markdown|": a finished chat with a reply that uses every Markdown block (UI tests, screenshots).
            let seed = DebugSeed.pendingRun?.engine
            guard seed == "markdown" || seed == "secrets" || seed == "fix" || seed == "checkoffer" else { return }
            DebugSeed.pendingRun = nil
            let thread = ChatThread(server: server, workingDirectory: server.workingDirectory, engine: .codex)
            if seed == "checkoffer" {
                thread.title = "Why is Shop down?"
                thread.messages = DebugSeed.checkOfferChat
                IncidentLinks.set("seeded", for: thread.id)
            } else if seed == "fix" {
                thread.title = "Why is Shop down?"
                thread.messages = DebugSeed.fixChat
            } else if seed == "secrets" {
                thread.title = "Why can't the app reach the database?"
                thread.messages = DebugSeed.secretsChat
            } else {
                thread.title = "Why does the API return 404?"
                thread.messages = [.user("Why does the weather API return 404 for some cities?"), DebugSeed.markdownReply]
            }
            context.insert(thread)
            openThread = thread
        }
        .task {
            guard let run = DebugSeed.pendingRun, let engine = Engine(rawValue: run.engine) else { return }
            DebugSeed.pendingRun = nil
            let thread = ChatThread(server: server, workingDirectory: server.workingDirectory, engine: engine)
            context.insert(thread)
            DebugSeed.pendingPrompt = run.prompt
            openThread = thread
        }
        #endif
    }
}

/// One engine as a tappable tile: logo, name, what it uses.
struct EngineTile: View {
    let engine: Engine
    /// false: needs a sign-in (CLI) or a key (own model) first.
    var ready = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrandIcon(brand: engine.brand, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.shortTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                if ready {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(engine == .ownKey ? String(localized: "Add a key") : String(localized: "Sign in"))
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline))
        .contentShape(RoundedRectangle(cornerRadius: Theme.corner))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ready ? Text("New task with \(engine.title)")
                            : engine == .ownKey ? Text("Add a key for \(engine.title)") : Text("Sign in to \(engine.title)"))
    }

    private var subtitle: String {
        switch engine {
        case .ownKey: AppSettings.shared.providerKind.displayName.components(separatedBy: " (").first ?? ""
        case .codex: String(localized: "ChatGPT plan")
        case .claudeCode: String(localized: "Claude plan")
        }
    }
}

/// One way to run a task, as a full-width row: works on every screen size.
struct EngineRow: View {
    let engine: Engine
    var ready = true

    var body: some View {
        HStack(spacing: 14) {
            BrandIcon(brand: engine.brand, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.shortTitle).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if ready {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            } else {
                Text(engine == .ownKey ? String(localized: "Add a key") : String(localized: "Sign in"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ready ? Text("New task with \(engine.title)")
                            : engine == .ownKey ? Text("Add a key for \(engine.title)") : Text("Sign in to \(engine.title)"))
    }

    private var detail: String {
        switch engine {
        case .claudeCode: String(localized: "Runs on this server with your Claude plan")
        case .codex: String(localized: "Runs on this server with your ChatGPT plan")
        case .ownKey:
            AppSettings.shared.isConfigured
                ? String(localized: "\(AppSettings.shared.providerKind.displayName.components(separatedBy: " (").first ?? "") · runs in the app")
                : String(localized: "Your own API key · runs in the app")
        }
    }
}
