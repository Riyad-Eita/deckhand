import SwiftData
import SwiftUI

struct ServerView: View {
    let server: Server

    enum Tab: String, CaseIterable, Identifiable {
        case agent = "Agent"
        case terminal = "Terminal"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .agent
    @State private var showingTools = false
    /// A command for the terminal to run once it is connected (e.g. a CLI login).
    @State private var terminalCommand: String?
    @Environment(Connections.self) private var connections

    init(server: Server) {
        self.server = server
        #if DEBUG
        if let run = DebugSeed.pendingRun, run.engine == "terminal" {
            _tab = State(initialValue: .terminal)
            if !run.prompt.isEmpty { _terminalCommand = State(initialValue: run.prompt) }
        }
        #endif
    }

    var body: some View {
        Group {
            switch tab {
            case .agent: ThreadListView(server: server)
            case .terminal: TerminalScreen(server: server, pendingCommand: $terminalCommand)
            }
        }
        .navigationTitle(server.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
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

struct ThreadListView: View {
    let server: Server
    @Environment(\.modelContext) private var context
    @State private var openThread: ChatThread?

    private var threads: [ChatThread] {
        (server.threads ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        List {
            Section {
                ForEach(Engine.allCases) { engine in
                    Button {
                        let thread = ChatThread(server: server, workingDirectory: server.workingDirectory, engine: engine)
                        context.insert(thread)
                        openThread = thread
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("New Task")
                                Text(engine.title).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: engine.symbol) }
                    }
                }
            } header: {
                Text("Start")
            } footer: {
                Text("Codex and Claude Code run on the server with your own subscription.")
            }
            if !threads.isEmpty {
                Section("Recent") {
                    ForEach(threads) { thread in
                        Button { openThread = thread } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(thread.title).foregroundStyle(.primary).lineLimit(1)
                                HStack(spacing: 4) {
                                    Text(thread.engine.title)
                                    Text("·")
                                    Text(thread.updatedAt, style: .relative)
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { context.delete(threads[i]) }
                    }
                }
            }
        }
        .navigationDestination(item: $openThread) { AgentChatView(thread: $0, server: server) }
        #if DEBUG
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
