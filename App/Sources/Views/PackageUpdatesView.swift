import DeckhandCore
import SwiftUI

/// Waiting package updates (apt / dnf): security first, install security or all, restart hint.
struct PackageUpdatesView: View {
    let server: Server

    @Environment(Connections.self) private var connections
    @State private var status: UpdateStatus?
    @State private var error: String?
    @State private var loading = true
    @State private var task: UpdateTask?

    struct UpdateTask: Identifiable {
        enum Kind { case refresh, security, all, reboot }
        let kind: Kind
        var id: String { "\(kind)" }
    }

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
            if let status {
                if status.manager == nil {
                    ContentUnavailableView(
                        "No apt or dnf", systemImage: "shippingbox",
                        description: Text("Deckhand handles updates on Debian, Ubuntu, Fedora, RHEL and similar servers."))
                } else {
                    summary(status)
                    if status.rebootRequired { rebootSection(status) }
                    if !status.security.isEmpty {
                        Section("Security") { ForEach(status.security) { PackageRow(update: $0) } }
                    }
                    if !status.other.isEmpty {
                        Section("Other updates") { ForEach(status.other) { PackageRow(update: $0) } }
                    }
                }
            }
        }
        .overlay { if loading && status == nil { ProgressView() } }
        .navigationTitle("Updates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { task = UpdateTask(kind: .refresh) } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Check for Updates")
                    .disabled(status?.manager == nil)
            }
        }
        .sheet(item: $task, onDismiss: { Task { await load() } }) { t in sheet(for: t) }
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func summary(_ s: UpdateStatus) -> some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: s.updates.isEmpty ? "checkmark.seal.fill" : s.security.isEmpty ? "arrow.down.circle.fill" : "exclamationmark.shield.fill")
                    .font(.title)
                    .foregroundStyle(s.updates.isEmpty ? .green : s.security.isEmpty ? Theme.accent : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline(s)).font(.headline)
                    Text(checked(s)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("updates.summary")
            if !s.security.isEmpty {
                Button { task = UpdateTask(kind: .security) } label: {
                    Label("Install Security Updates (\(s.security.count))", systemImage: "lock.shield")
                }
                .accessibilityIdentifier("updates.security")
            }
            if !s.updates.isEmpty {
                Button { task = UpdateTask(kind: .all) } label: {
                    Label("Install All Updates (\(s.updates.count))", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("updates.all")
            }
        } footer: {
            if (s.listAgeDays ?? 0) > 7 {
                Text("The package lists are \(s.listAgeDays ?? 0) days old — check for updates to see the latest.")
            }
        }
    }

    private func rebootSection(_ s: UpdateStatus) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Restart needed", systemImage: "arrow.triangle.2.circlepath").font(.headline).foregroundStyle(.orange)
                Text("Updates are installed but only take effect after a restart.").font(.subheadline)
                if !s.rebootReasons.isEmpty {
                    Text(s.rebootReasons.prefix(6).joined(separator: ", ")).font(Theme.monoSmall).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityIdentifier("updates.reboot")
            Button(role: .destructive) { task = UpdateTask(kind: .reboot) } label: {
                Label("Restart Server…", systemImage: "power")
            }
        }
    }

    @ViewBuilder
    private func sheet(for t: UpdateTask) -> some View {
        let pm = status?.manager ?? "apt"
        switch t.kind {
        case .refresh:
            RootTaskSheet(
                server: server, title: "Check for Updates",
                summary: "Downloads the latest package lists. Nothing is installed.",
                files: [], script: PackageUpdates.refreshScript(pm), steps: [("refresh", "Refresh the package lists")],
                confirm: "Check")
        case .security:
            RootTaskSheet(
                server: server, title: "Install Security Updates",
                summary: "Installs \(status?.security.count ?? 0) security updates. Services may restart briefly. Your changed config files are kept. This can't be rolled back.",
                files: [], script: PackageUpdates.installScript(pm, packages: status?.security.map(\.name) ?? []),
                steps: [("refresh", "Refresh the package lists"), ("install", "Install the updates")], confirm: "Install")
        case .all:
            RootTaskSheet(
                server: server, title: "Install All Updates",
                summary: "Installs \(status?.updates.count ?? 0) updates. Services may restart briefly. Your changed config files are kept. This can't be rolled back.",
                files: [], script: PackageUpdates.installScript(pm),
                steps: [("refresh", "Refresh the package lists"), ("install", "Install the updates")], confirm: "Install")
        case .reboot:
            RootTaskSheet(
                server: server, title: "Restart Server",
                summary: "The server restarts in a few seconds and is unreachable for a minute or two. Running tasks, terminals and web apps stop; services set to start at boot come back.",
                files: [], script: PackageUpdates.rebootScript, steps: [("reboot", "Restart")],
                confirm: "Restart", destructive: true)
        }
    }

    private func headline(_ s: UpdateStatus) -> String {
        if s.updates.isEmpty { return String(localized: "Up to date") }
        if s.security.isEmpty { return String(localized: "\(s.updates.count) updates waiting") }
        return String(localized: "\(s.updates.count) updates, \(s.security.count) for security")
    }

    private func checked(_ s: UpdateStatus) -> String {
        let manager = s.manager ?? ""
        guard let days = s.listAgeDays else { return manager }
        let when = days == 0 ? String(localized: "today") : days == 1 ? String(localized: "yesterday") : String(localized: "\(days) days ago")
        return String(localized: "\(manager) · lists from \(when)")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let conn = try await connections.connection(for: server)
            status = PackageUpdates.parse(try await conn.run(PackageUpdates.statusCommand, timeout: .seconds(120)).stdout)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PackageRow: View {
    let update: PackageUpdate
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(update.name).font(.body)
            HStack(spacing: 4) {
                if let current = update.current {
                    Text(current).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "arrow.right").font(.caption2)
                }
                Text(update.available).lineLimit(1).truncationMode(.middle)
            }
            .font(Theme.monoSmall).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
