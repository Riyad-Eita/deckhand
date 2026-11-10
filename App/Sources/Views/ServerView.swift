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

    private var threads: [ChatThread] {
        (server.threads ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    ForEach([Engine.claudeCode, .codex, .ownKey]) { engine in
                        Button { pickingFolderFor = engine } label: { EngineTile(engine: engine) }
                            .buttonStyle(.plain)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("New task")
            } footer: {
                Text("Claude Code and Codex run on your server with your own subscription. “Your key” uses the model you set up in Settings.")
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
                                        Text(thread.updatedAt, style: .relative)
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
            guard DebugSeed.pendingRun?.engine == "markdown" else { return }
            DebugSeed.pendingRun = nil
            let thread = ChatThread(server: server, workingDirectory: server.workingDirectory, engine: .codex)
            thread.title = "Why does the API return 404?"
            thread.messages = [.user("Why does the weather API return 404 for some cities?"), DebugSeed.markdownReply]
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrandIcon(brand: engine.brand, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.shortTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline))
        .contentShape(RoundedRectangle(cornerRadius: Theme.corner))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New task with \(engine.title)")
    }

    private var subtitle: String {
        switch engine {
        case .ownKey: AppSettings.shared.providerKind.displayName.components(separatedBy: " (").first ?? ""
        case .codex: String(localized: "ChatGPT plan")
        case .claudeCode: String(localized: "Claude plan")
        }
    }
}
