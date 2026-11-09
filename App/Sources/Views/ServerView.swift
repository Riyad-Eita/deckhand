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
    @State private var path: [ChatThread] = []
    @State private var openThread: ChatThread?

    private var threads: [ChatThread] {
        (server.threads ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        List {
            Section {
                Button {
                    let thread = ChatThread(server: server, workingDirectory: server.workingDirectory)
                    context.insert(thread)
                    openThread = thread
                } label: {
                    Label("New Task", systemImage: "plus.bubble")
                }
            }
            if !threads.isEmpty {
                Section("Recent") {
                    ForEach(threads) { thread in
                        Button { openThread = thread } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(thread.title).foregroundStyle(.primary).lineLimit(1)
                                Text(thread.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
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
    }
}
