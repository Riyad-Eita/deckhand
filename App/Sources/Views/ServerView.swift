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
    @Environment(Connections.self) private var connections

    init(server: Server) {
        self.server = server
        #if DEBUG
        if DebugSeed.pendingRun?.engine == "terminal" { _tab = State(initialValue: .terminal) }
        #endif
    }

    var body: some View {
        Group {
            switch tab {
            case .agent: ThreadListView(server: server)
            case .terminal: TerminalScreen(server: server)
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
                StatusDot(state: connections.state(for: server))
            }
        }
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
