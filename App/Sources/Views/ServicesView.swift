import DeckhandCore
import SwiftUI

/// systemd services on one server: failed first, search, tap for details.
struct ServicesView: View {
    let server: Server

    @Environment(Connections.self) private var connections
    @State private var units: [ServiceUnit] = []
    @State private var query = ""
    @State private var showAll = false
    @State private var loading = true
    @State private var error: String?

    private var visible: [ServiceUnit] {
        let base = showAll ? units : units.filter { $0.isFailed || $0.isRunning }
        guard !query.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if let error {
                ProblemView(message: error, compact: true)
            }
            Section {
                ForEach(visible) { unit in
                    NavigationLink {
                        ServiceDetailView(server: server, unit: unit)
                    } label: {
                        ServiceRow(unit: unit)
                    }
                }
            } header: {
                if !units.isEmpty {
                    let failed = units.filter(\.isFailed).count
                    Text(failed > 0 ? "\(failed) failed · \(units.filter(\.isRunning).count) running" : "\(units.filter(\.isRunning).count) running")
                }
            } footer: {
                Toggle("Show stopped services", isOn: $showAll).font(.footnote)
            }
        }
        .overlay { if loading && units.isEmpty { ProgressView() } }
        .searchable(text: $query, prompt: "Search services")
        .navigationTitle("Services")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let conn = try await connections.connection(for: server)
            units = Services.parse(try await conn.run(Services.listCommand, timeout: .seconds(20)).stdout)
            error = units.isEmpty ? "No systemd services found on this server." : nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ServiceRow: View {
    let unit: ServiceUnit
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(unit.shortName).font(.body.weight(.medium))
                Text(unit.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(unit.isFailed ? "failed" : unit.sub).font(.caption).foregroundStyle(unit.isFailed ? .red : .secondary)
        }
    }
    private var color: Color { unit.isFailed ? .red : unit.isRunning ? .green : .secondary.opacity(0.4) }
}

struct ServiceDetailView: View {
    let server: Server
    let unit: ServiceUnit

    @Environment(Connections.self) private var connections
    @Environment(\.dismiss) private var dismiss
    @State private var status = ""
    @State private var logs = ""
    @State private var busy: ServiceAction?
    @State private var confirm: ServiceAction?
    @State private var needsTerminal: String?
    @State private var message: String?
    @State private var terminal: TerminalRequest?
    @State private var investigatePrompt: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Circle().fill(unit.isFailed ? Color.red : unit.isRunning ? .green : .secondary.opacity(0.4)).frame(width: 10, height: 10)
                    VStack(alignment: .leading) {
                        Text(unit.description).font(.headline)
                        Text("\(unit.active) · \(unit.sub)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if unit.isFailed {
                    Button {
                        investigatePrompt = ("The service \(unit.name) has failed on this server. Read its status and recent logs, find the cause and suggest a fix. Don't change anything yet — ask me first.")
                    } label: {
                        Label("Investigate with an agent", systemImage: "sparkle.magnifyingglass")
                    }
                }
            }
            Section("Actions") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ServiceAction.allCases, id: \.self) { action in
                            Button {
                                if action.isDisruptive { confirm = action } else { Task { await run(action) } }
                            } label: {
                                HStack(spacing: 4) {
                                    if busy == action { ProgressView().controlSize(.mini) }
                                    Text(LocalizedStringKey(action.title))
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(action.isDisruptive ? .red : Theme.accent)
                            .disabled(busy != nil)
                        }
                    }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            Section("Status") {
                Text(status.isEmpty ? "…" : status).font(Theme.monoSmall).textSelection(.enabled)
            }
            Section("Recent logs") {
                if logs == "@@nojournal" {
                    Text(Services.noJournalHint).font(.footnote).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        Text(logs.isEmpty ? "No entries." : logs).font(Theme.monoSmall).textSelection(.enabled).fixedSize()
                    }
                }
            }
        }
        .navigationTitle(unit.shortName)
        .navigationBarTitleDisplayMode(.inline)
        .investigate(on: server, prompt: $investigatePrompt)
        .sheet(item: $terminal, onDismiss: { Task { await refresh() } }) { request in
            TerminalSheet(server: server, command: request.command)
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .confirmationDialog("\(confirm?.title ?? "") \(unit.shortName)?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button(confirm?.title ?? "", role: .destructive) {
                if let a = confirm { Task { await run(a) } }
            }
        } message: {
            Text("This can take whatever depends on \(unit.shortName) offline.")
        }
        .alert("Password needed", isPresented: Binding(get: { needsTerminal != nil }, set: { if !$0 { needsTerminal = nil } })) {
            Button("Run in Terminal") {
                if let cmd = needsTerminal { terminal = TerminalRequest(command: cmd) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The server asks for your sudo password for this. Deckhand opens the terminal with the command so you can type it there.")
        }
    }

    private func run(_ action: ServiceAction) async {
        busy = action
        defer { busy = nil }
        do {
            let conn = try await connections.connection(for: server)
            let r = try await conn.run(Services.actionCommand(action, unit: unit.name), timeout: .seconds(60))
            try Services.check(r, action: action, unit: unit.name)
            message = String(localized: "\(action.title) done.")
            await refresh()
        } catch let ServiceError.needsPassword(command) {
            needsTerminal = command
        } catch {
            message = error.localizedDescription
        }
    }

    private func refresh() async {
        guard let conn = try? await connections.connection(for: server) else { return }
        async let s = conn.run(Services.statusCommand(unit.name), timeout: .seconds(20))
        async let l = conn.run(Services.logsCommand(unit.name), timeout: .seconds(30))
        status = (try? await s)?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? status
        logs = (try? await l)?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? logs
    }
}

struct TerminalRequest: Identifiable {
    let id = UUID()
    let command: String
}

/// A terminal over the current screen that runs one command (e.g. a sudo action) and stays open.
struct TerminalSheet: View {
    let server: Server
    @State var command: String?
    @Environment(\.dismiss) private var dismiss

    init(server: Server, command: String) {
        self.server = server
        _command = State(initialValue: command)
    }

    var body: some View {
        NavigationStack {
            TerminalScreen(server: server, pendingCommand: $command)
                .navigationTitle("Terminal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .hostKeyPrompt(inSheet: true)
    }
}
