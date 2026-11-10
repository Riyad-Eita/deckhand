import DeckhandCore
import SwiftUI

extension View {
    /// Asks for the sudo password when `runner` needs it, then continues.
    func sudoPassword(_ runner: RootRunner, server: Server) -> some View {
        modifier(SudoPasswordAlert(runner: runner, server: server))
    }
}

private struct SudoPasswordAlert: ViewModifier {
    @Bindable var runner: RootRunner
    let server: Server
    func body(content: Content) -> some View {
        content.alert("Sudo password", isPresented: $runner.passwordPrompt) {
            SecureField("Password", text: $runner.password)
            Button("Continue") { runner.submitPassword() }
            Button("Cancel", role: .cancel) { runner.cancel() }
        } message: {
            Text("for \(server.username) on \(server.displayName). Deckhand keeps it in memory until you quit the app.")
        }
    }
}

/// Shows what a root task will do, runs it with a live step list and reports the result.
struct RootTaskSheet: View {
    let server: Server
    let title: LocalizedStringKey
    let summary: LocalizedStringKey
    let files: [String]
    let script: String
    /// `@@step` names in order with their labels.
    let steps: [(String, LocalizedStringKey)]
    var confirm: LocalizedStringKey = "Apply"
    var destructive = false
    var finished: (Bool) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var runner = RootRunner()
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(summary).font(.subheadline)
                }
                if !files.isEmpty {
                    Section {
                        ForEach(files, id: \.self) { Text($0).font(Theme.monoSmall) }
                    } header: {
                        Text("Files")
                    } footer: {
                        if steps.contains(where: { $0.0 == "backup" }) {
                            Text("Backed up on the server before anything changes. If the check fails, they're put back at once.")
                        }
                    }
                }
                if runner.phase != .idle && runner.phase != .needsPassword || !runner.steps.isEmpty {
                    Section("Progress") {
                        ForEach(steps, id: \.0) { step in
                            HStack(spacing: 10) {
                                stepIcon(step.0).frame(width: 20)
                                Text(step.1)
                            }
                        }
                    }
                }
                if case .failed(let message) = runner.phase {
                    Section { Text(message).foregroundStyle(.red).font(.footnote) }
                }
                if let failed = runner.failedStep {
                    Section {
                        Label("The \(label(for: failed)) step failed. Your previous files were put back.", systemImage: "arrow.uturn.backward.circle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                if !runner.lines.isEmpty {
                    Section {
                        DisclosureGroup("Output", isExpanded: $showLog) {
                            Text(runner.lines.suffix(300).joined(separator: "\n")).font(Theme.monoSmall).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isDone ? "Done" : "Cancel") { runner.cancel(); dismiss() }.disabled(runner.isRunning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning { ProgressView() } else if !isDone {
                        Button(confirm) { runner.start(script, on: server) }
                            .tint(destructive ? .red : Theme.accent)
                            .accessibilityIdentifier("rootTask.confirm")
                    }
                }
            }
            .sudoPassword(runner, server: server)
            .onChange(of: runner.phase) { _, phase in if case .finished = phase { finished(runner.succeeded) } }
            .interactiveDismissDisabled(runner.isRunning)
        }
    }

    private var isDone: Bool { if case .finished = runner.phase { true } else { false } }

    private func label(for step: String) -> LocalizedStringKey { steps.first { $0.0 == step }?.1 ?? LocalizedStringKey(step) }

    @ViewBuilder private func stepIcon(_ step: String) -> some View {
        let seen = runner.steps.contains(step)
        let isLast = runner.steps.last == step
        if runner.failedStep == step {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else if seen && (!isLast || runner.succeeded || runner.failedStep != nil) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if seen && runner.isRunning {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    static let changeSteps: [(String, LocalizedStringKey)] = [
        ("backup", "Back up the files"), ("apply", "Make the change"),
        ("validate", "Check the configuration"), ("reload", "Reload the service"),
    ]
    static let rollbackSteps: [(String, LocalizedStringKey)] = [
        ("restore", "Restore the backed-up files"), ("validate", "Check the configuration"), ("reload", "Reload the service"),
    ]
}

/// Every change Deckhand made on this server, with a diff and a one-tap rollback.
struct ChangesView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var records: [ConfigChange.Record]?
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            if let records {
                if records.isEmpty {
                    ContentUnavailableView(
                        "No changes yet", systemImage: "clock.arrow.circlepath",
                        description: Text("Security changes made with Deckhand show up here. Each one keeps a backup you can go back to."))
                } else {
                    Section {
                        ForEach(records) { r in
                            NavigationLink { ChangeDetailView(server: server, record: r) { Task { await load() } } } label: { ChangeRow(record: r) }
                        }
                    } footer: {
                        Text("Backups live in \(ConfigChange.defaultRoot) on the server.")
                    }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Change history")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            records = ConfigChange.parseList(try await conn.run(ConfigChange.listCommand(), timeout: .seconds(20)).stdout)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ChangeRow: View {
    let record: ConfigChange.Record
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                Text(record.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            ChangeStatusPill(status: record.status)
        }
    }
}

struct ChangeStatusPill: View {
    let status: ConfigChange.Status
    var body: some View {
        let (text, color): (Text, Color) = switch status {
        case .applied: (Text("Applied"), .green)
        case .failed: (Text("Undone automatically"), .orange)
        case .rolledback: (Text("Rolled back"), .secondary)
        case .unknown: (Text("Interrupted"), .red)
        }
        text.font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
    }
}

struct ChangeDetailView: View {
    let server: Server
    let record: ConfigChange.Record
    let changed: () -> Void
    @State private var diff = RootRunner()
    @State private var rollingBack = false
    @State private var rolledBack = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                LabeledContent("Status") { ChangeStatusPill(status: record.status) }
                LabeledContent("Made", value: record.created.formatted(date: .abbreviated, time: .shortened))
            }
            Section("Files") {
                ForEach(record.files, id: \.self) { Text($0).font(Theme.monoSmall) }
            }
            Section {
                switch diff.phase {
                case .idle:
                    Button("Show the difference to now") { diff.start(ConfigChange.diffScript(id: record.id), on: server) }
                case .running, .needsPassword:
                    HStack { ProgressView(); Text("Comparing…").foregroundStyle(.secondary) }
                case .failed(let m):
                    Text(m).foregroundStyle(.red).font(.footnote)
                case .finished:
                    if diff.lines.isEmpty {
                        Text("The files are the same as before this change.").foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal) { DiffText(lines: diff.lines) }
                    }
                }
            } header: {
                Text("Before → now")
            }
            if record.status == .applied {
                Section {
                    Button(role: .destructive) { rollingBack = true } label: { Label("Roll back", systemImage: "arrow.uturn.backward") }
                } footer: {
                    Text("Puts the files back as they were before this change and reloads the service.")
                }
            }
        }
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
        .sudoPassword(diff, server: server)
        .sheet(isPresented: $rollingBack, onDismiss: { if rolledBack { dismiss() } }) {
            RootTaskSheet(
                server: server, title: "Roll back", summary: "Restores the files from the backup made before “\(record.title)”, checks the configuration and reloads the service.",
                files: record.files, script: ConfigChange.rollbackScript(id: record.id), steps: RootTaskSheet.rollbackSteps,
                confirm: "Roll back", destructive: true) { ok in if ok { rolledBack = true; changed() } }
        }
    }
}

/// A unified diff with added and removed lines tinted.
struct DiffText: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line).font(Theme.monoSmall)
                    .foregroundStyle(color(line))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(line))
            }
        }
        .textSelection(.enabled)
        .fixedSize()
    }
    private func color(_ l: String) -> Color {
        if l.hasPrefix("+++") || l.hasPrefix("---") { return .secondary }
        if l.hasPrefix("+") { return .green }
        if l.hasPrefix("-") { return .red }
        if l.hasPrefix("@@") { return Theme.accent }
        return .primary
    }
    private func background(_ l: String) -> Color {
        if l.hasPrefix("+") && !l.hasPrefix("+++") { return .green.opacity(0.08) }
        if l.hasPrefix("-") && !l.hasPrefix("---") { return .red.opacity(0.08) }
        return .clear
    }
}
