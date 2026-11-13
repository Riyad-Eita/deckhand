import DeckhandCore
import SwiftData
import SwiftUI

/// Type to jump: servers, tasks, chats and recent folders — or an action like "restart nginx on web-1".
struct CommandPaletteView: View {
    let openServer: (Server) -> Void
    let openChat: (ChatThread) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(Connections.self) private var connections
    @Query(sort: \Server.createdAt) private var servers: [Server]
    @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]
    @State private var query = ""
    @State private var root = RootRunner()
    @State private var actionServer: Server?
    @State private var output: [String] = []
    @State private var running = false
    @State private var confirmStop = false
    @FocusState private var focused: Bool

    private var action: CommandPalette.Action? { CommandPalette.action(query) }

    /// The server an action names (by name or host), or the only one there is.
    private var resolvedServer: Server? {
        guard let a = action else { return nil }
        if let name = a.server {
            return servers.compactMap { s in CommandPalette.score(name, s.displayName).map { (s, $0) } }.max { $0.1 < $1.1 }?.0
        }
        return actionServer ?? (servers.count == 1 ? servers.first : nil)
    }

    private func ranked<T>(_ items: [T], _ text: (T) -> String, limit: Int) -> [T] {
        guard !query.isEmpty else { return Array(items.prefix(limit)) }
        return items.compactMap { i in CommandPalette.score(query, text(i)).map { (i, $0) } }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    var body: some View {
        NavigationStack {
            List {
                if let a = action { actionSection(a) }
                let s = ranked(servers, { "\($0.displayName) \($0.host) \($0.group)" }, limit: 6)
                if !s.isEmpty {
                    Section("Servers") {
                        ForEach(s) { server in
                            Button { dismiss(); openServer(server) } label: {
                                Label { Text(server.displayName) } icon: { Image(systemName: "server.rack") }
                            }
                            .accessibilityIdentifier("palette.server.\(server.displayName)")
                        }
                    }
                }
                let t = ranked(threads, { $0.title }, limit: 8)
                if !t.isEmpty {
                    Section("Tasks and chats") {
                        ForEach(t) { thread in
                            Button {
                                dismiss()
                                if thread.isPlainChat { openChat(thread) } else { AppRouter.shared.pendingThread = thread.id }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(thread.title).lineLimit(1)
                                    Text(thread.server?.displayName ?? String(localized: "Chat")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("palette.thread")
                        }
                    }
                }
                let folders = ranked(servers.flatMap { s in s.recentDirectories.prefix(5).map { (s, $0) } }, { "\($0.1) \($0.0.displayName)" }, limit: 5)
                if !query.isEmpty && !folders.isEmpty {
                    Section("Folders") {
                        ForEach(folders, id: \.1) { pair in
                            Button { dismiss(); openServer(pair.0) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pair.1).font(Theme.mono)
                                    Text(pair.0.displayName).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if query.isEmpty {
                    Section {} footer: { Text("Try “restart nginx on web-1”, “logs of shop”, or a server or task name.") }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Servers, tasks, or an action")
            .searchFocused($focused)
            .onAppear { focused = true }
            .navigationTitle("Go to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sudoPassword(root, server: resolvedServer ?? servers.first ?? Server(name: "", host: "", username: "", authKind: .key))
            .confirmationDialog("Stop \(action?.service ?? "") on \(resolvedServer?.displayName ?? "")?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop", role: .destructive) { Task { await run() } }
            }
        }
    }

    @ViewBuilder private func actionSection(_ a: CommandPalette.Action) -> some View {
        Section {
            if resolvedServer == nil {
                Text("On which server?").font(.subheadline).foregroundStyle(.secondary)
                ForEach(servers) { s in
                    Button(s.displayName) { actionServer = s }
                }
            } else if let server = resolvedServer {
                Button {
                    if a.verb.disruptive { confirmStop = true } else { Task { await run() } }
                } label: {
                    HStack {
                        Label("\(a.verb.rawValue.capitalized) \(a.service) on \(server.displayName)", systemImage: a.verb == .logs ? "text.alignleft" : a.verb == .status ? "info.circle" : "arrow.clockwise")
                        Spacer()
                        if running { ProgressView() }
                    }
                }
                .disabled(running)
                .accessibilityIdentifier("palette.action")
                if !output.isEmpty {
                    Text(output.suffix(40).joined(separator: "\n")).font(Theme.monoSmall).foregroundStyle(.secondary).textSelection(.enabled)
                        .accessibilityIdentifier("palette.output")
                }
            }
        } header: {
            Text("Action")
        }
    }

    private func run() async {
        guard let a = action, let server = resolvedServer else { return }
        running = true
        defer { running = false }
        output = []
        if a.verb.needsRoot {
            _ = await root.run(CommandPalette.command(a), on: server)
            output = root.lines
        } else {
            do {
                let conn = try await connections.connection(for: server)
                let r = try await conn.run(CommandPalette.command(a), timeout: .seconds(30))
                output = (r.stdout + r.stderr).split(separator: "\n").map(String.init)
            } catch { output = [error.localizedDescription] }
        }
    }
}
