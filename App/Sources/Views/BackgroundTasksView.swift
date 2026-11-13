import DeckhandCore
import SwiftUI

/// Claude Code and Codex tasks that run on the server on their own — also while the phone is off.
struct BackgroundTasksView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var runs: [DetachedRun.Info]?
    @State private var error: String?
    @State private var confirmStop: DetachedRun.Info?

    private var threadsByRun: [String: ChatThread] {
        Dictionary((server.threads ?? []).compactMap { t in t.cliRunID.map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let runs {
                if runs.isEmpty {
                    ContentUnavailableView(
                        "No background tasks", systemImage: "moon.zzz",
                        description: Text("Tasks you give Claude Code or Codex keep running here when you close the app or lose the connection."))
                } else {
                    let active = runs.filter(\.status.isActive)
                    let ended = runs.filter { !$0.status.isActive }
                    if !active.isEmpty {
                        Section("Running") { ForEach(active) { row($0) } }
                    }
                    if !ended.isEmpty {
                        Section {
                            ForEach(ended) { row($0) }
                        } header: {
                            HStack {
                                Text("Finished")
                                Spacer()
                                Button("Clear") { Task { await clear(ended) } }.font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
            Section {
            } footer: {
                Text("If a task hits your plan's usage limit, it waits on the server until the limit resets and then continues by itself.")
            }
        }
        .navigationTitle("Background tasks")
        .task {
            // Refresh while the screen is open.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .refreshable { await load() }
        .confirmationDialog("Stop \(confirmStop?.meta?.title ?? "")?", isPresented: Binding(get: { confirmStop != nil }, set: { if !$0 { confirmStop = nil } }), titleVisibility: .visible) {
            Button("Stop task", role: .destructive) { if let r = confirmStop { Task { await stop(r) } } }
        } message: {
            Text("The agent is stopped on the server. Changes it already made stay.")
        }
    }

    @ViewBuilder private func row(_ info: DetachedRun.Info) -> some View {
        let thread = threadsByRun[info.id]
        Group {
            if let thread {
                NavigationLink { AgentChatView(thread: thread, server: server) } label: { RunRow(info: info) }
            } else {
                RunRow(info: info)
            }
        }
        .swipeActions {
            if info.status.isActive {
                Button("Stop") { confirmStop = info }.tint(.red)
            } else {
                Button("Delete") { Task { await clear([info]) } }.tint(.red)
            }
        }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            runs = DetachedRun.parseList(try await conn.run(DetachedRun.listCommand, timeout: .seconds(20)).stdout)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stop(_ info: DetachedRun.Info) async {
        guard let conn = try? await connections.connection(for: server) else { return }
        _ = try? await conn.run(info.run.stopCommand, timeout: .seconds(15))
        if let thread = threadsByRun[info.id] { thread.cliRunActive = false }
        await load()
    }

    private func clear(_ infos: [DetachedRun.Info]) async {
        guard let conn = try? await connections.connection(for: server) else { return }
        _ = try? await conn.run(infos.map(\.run.deleteCommand).joined(separator: "; "), timeout: .seconds(15))
        await load()
    }
}

private struct RunRow: View {
    let info: DetachedRun.Info
    var body: some View {
        HStack(spacing: 12) {
            BrandIcon(brand: info.meta?.engine == ServerCLI.codex.displayName ? .codex : .claude, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(info.meta?.title ?? info.id).lineLimit(2)
                HStack(spacing: 4) {
                    if let meta = info.meta {
                        Text(meta.directory).lineLimit(1).truncationMode(.head)
                        Text("·")
                        Text(meta.started, format: .relative(presentation: .named))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            StatusPill(status: info.status)
        }
    }
}

private struct StatusPill: View {
    let status: DetachedRun.Status
    var body: some View {
        let (text, color): (Text, Color) = switch status {
        case .running: (Text("Running"), Theme.accent)
        case .waiting(let until): (Text("Waits until \(until.formatted(.dateTime.hour().minute()))"), .orange)
        case .ended(0): (Text("Done"), .green)
        case .ended(143): (Text("Stopped"), .secondary)
        case .ended: (Text("Failed"), .red)
        }
        text.font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
    }
}
