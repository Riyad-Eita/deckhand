import DeckhandCore
import SwiftData
import SwiftUI

/// One command on several servers: pick servers (or a group), run at once or one after another, results side by side.
struct FleetRunView: View {
    @Environment(Connections.self) private var connections
    @Query(sort: \Server.createdAt) private var servers: [Server]
    @State private var selected: Set<UUID> = []
    @State private var command = ""
    @State private var stopOnFailure = false
    @State private var states: [UUID: FleetRun.State] = [:]
    @State private var running = false
    @State private var confirmDanger: String?

    private var groups: [String] { Array(Set(servers.map(\.group).filter { !$0.isEmpty })).sorted() }
    private var chosen: [Server] { servers.filter { selected.contains($0.id) } }

    var body: some View {
        List {
            Section {
                if !groups.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip(String(localized: "All")) { selected = Set(servers.map(\.id)) }
                            ForEach(groups, id: \.self) { g in
                                chip(g) { selected = Set(servers.filter { $0.group == g }.map(\.id)) }
                            }
                        }
                    }
                }
                ForEach(servers) { s in
                    Button {
                        if selected.contains(s.id) { selected.remove(s.id) } else { selected.insert(s.id) }
                    } label: {
                        HStack {
                            Image(systemName: selected.contains(s.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(s.id) ? Theme.accent : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.displayName).foregroundStyle(.primary)
                                Text(s.group.isEmpty ? s.address : "\(s.group) · \(s.address)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("fleet.server.\(s.displayName)")
                }
            } header: {
                Text("Servers")
            }
            Section {
                TextField("Command", text: $command, axis: .vertical)
                    .font(Theme.mono).lineLimit(1...5)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("fleet.command")
                Menu {
                    ForEach(FleetRun.quickCommands, id: \.command) { q in
                        Button(LocalizedStringKey(q.title)) { command = q.command }
                    }
                } label: { Label("Quick commands", systemImage: "bolt") }
                .accessibilityIdentifier("fleet.quick")
                Toggle("Stop at the first failure", isOn: $stopOnFailure)
                Button {
                    if let danger = DangerCheck.assess(command: command) { confirmDanger = danger } else { Task { await run() } }
                } label: {
                    HStack {
                        Label(String(localized: "Run on \(chosen.count) servers"), systemImage: "play.fill")
                        Spacer()
                        if running { ProgressView() }
                    }
                }
                .disabled(running || chosen.isEmpty || command.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("fleet.run")
            } footer: {
                Text(stopOnFailure ? "One server after another; the rest are skipped after a failure."
                     : "All servers at once. Runs as each server's login user.")
            }
            if !states.isEmpty {
                Section("Results") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(chosen) { s in ResultCard(server: s, state: states[s.id] ?? .waiting) }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("Run on several servers")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("This command can do damage", isPresented: Binding(get: { confirmDanger != nil }, set: { if !$0 { confirmDanger = nil } }),
                            titleVisibility: .visible) {
            Button(String(localized: "Run on \(chosen.count) servers"), role: .destructive) { Task { await run() } }
        } message: { Text(confirmDanger ?? "") }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.bordered).controlSize(.small)
    }

    private func run() async {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        running = true
        defer { running = false }
        let targets = chosen
        states = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, FleetRun.State.waiting) })
        let connections = self.connections
        let fleet = targets.map { s in
            FleetRun.Target(id: s.id) { @MainActor in try await connections.connection(for: s) as any RemoteShell }
        }
        await FleetRun.run(command, on: fleet, stopOnFailure: stopOnFailure) { id, state in
            await MainActor.run { states[id] = state }
        }
    }
}

private struct ResultCard: View {
    let server: Server
    let state: FleetRun.State
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                icon
                Text(server.displayName).font(.subheadline.weight(.semibold))
                Spacer()
                if case .done(let code, _, let secs) = state {
                    Text(code == 0 ? String(format: "%.1f s", secs) : String(localized: "exit \(code)"))
                        .font(.caption.monospacedDigit()).foregroundStyle(code == 0 ? Color.secondary : Color.red)
                }
            }
            switch state {
            case .done(_, let out, _):
                if !out.isEmpty {
                    Text(out).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(expanded ? nil : 8)
                        .textSelection(.enabled)
                        .onTapGesture { expanded.toggle() }
                } else {
                    Text("No output").font(.caption).foregroundStyle(.tertiary)
                }
            case .failed(let e): Text(e).font(.caption).foregroundStyle(.red)
            case .skipped: Text("Skipped after a failure").font(.caption).foregroundStyle(.secondary)
            case .waiting, .running: EmptyView()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.result.\(server.displayName)")
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .skipped: Image(systemName: "forward.end").foregroundStyle(.secondary)
        case .failed: Image(systemName: "wifi.exclamationmark").foregroundStyle(.red)
        case .done(let code, _, _): Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(code == 0 ? .green : .red)
        }
    }
}
