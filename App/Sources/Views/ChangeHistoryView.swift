import DeckhandCore
import SwiftUI

/// What changed on the server, and when: snapshots every 15 minutes, grouped by day, each with a readable diff.
struct ChangeHistoryView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var timeline: ChangeHistory.Timeline?
    @State private var error: String?
    @State private var busy = false
    @State private var since: Date?
    @State private var pickingDate = false

    private var days: [(day: Date, snapshots: [ChangeHistory.Snapshot])] {
        let groups = Dictionary(grouping: timeline?.snapshots ?? []) { Calendar.current.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let timeline {
                if !timeline.installed {
                    Section {
                        Label("Every 15 minutes your server notes its packages, services, open ports, containers, cron jobs, users and config files. When something breaks, you see exactly what changed — and who changed it.", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline)
                        Button("Turn on change history") { Task { await install() } }
                            .disabled(busy || !timeline.hasDiff)
                            .accessibilityIdentifier("history.install")
                    } footer: {
                        Text(timeline.hasDiff ? "Stays on your server in ~/.deckhand/history. Private keys and password files are left out."
                             : "This server has no diff command, which the history needs.")
                    }
                } else {
                    if !timeline.cron {
                        Text("This server has no cron, so a snapshot is only taken when you open this screen.").font(.footnote).foregroundStyle(.orange)
                    }
                    ForEach(days, id: \.day) { day in
                        Section {
                            ForEach(day.snapshots) { snap in
                                if snap.isStart {
                                    SnapshotRow(snapshot: snap)
                                } else {
                                    NavigationLink {
                                        ChangesDetailView(server: server, title: snap.date.formatted(date: .abbreviated, time: .shortened),
                                                          command: ChangeHistory.showCommand(snap.stamp))
                                    } label: { SnapshotRow(snapshot: snap) }
                                }
                            }
                        } header: {
                            Text(day.day, format: .dateTime.weekday(.wide).day().month())
                        }
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Change history")
        .toolbar {
            if timeline?.installed == true {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Last hour") { since = Date().addingTimeInterval(-3600) }
                        Button("Last 24 hours") { since = Date().addingTimeInterval(-86_400) }
                        Button("Last 7 days") { since = Date().addingTimeInterval(-7 * 86_400) }
                        Button("Pick a time…") { pickingDate = true }
                    } label: { Label("What changed since…", systemImage: "calendar.badge.clock") }
                        .accessibilityIdentifier("history.since")
                }
            }
        }
        .navigationDestination(item: $since) { date in
            ChangesDetailView(server: server, title: String(localized: "Since \(date.formatted(date: .abbreviated, time: .shortened))"),
                              command: ChangeHistory.sinceCommand(date))
        }
        .sheet(isPresented: $pickingDate) { SincePicker { since = $0 } }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            timeline = ChangeHistory.parseTimeline(try await conn.run(ChangeHistory.timelineCommand, timeout: .seconds(90)).stdout)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func install() async {
        busy = true
        defer { busy = false }
        do {
            let conn = try await connections.connection(for: server)
            _ = try await conn.run(ChangeHistory.installCommand, timeout: .seconds(120))
        } catch {
            self.error = error.localizedDescription
        }
        await load()
    }
}

private struct SnapshotRow: View {
    let snapshot: ChangeHistory.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(snapshot.date, format: .dateTime.hour().minute()).font(.subheadline.monospacedDigit().weight(.medium))
                Spacer()
            }
            if snapshot.isStart {
                Text("History starts here").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(snapshot.causes.enumerated()), id: \.offset) { _, cause in
                switch cause {
                case .packageManager(let cmd):
                    Label(cmd, systemImage: "shippingbox").font(.caption.monospaced()).lineLimit(2)
                case .deckhand:
                    Label("Changed with Deckhand", systemImage: "wrench.and.screwdriver").font(.caption)
                case .agent:
                    Label("During an agent task", systemImage: "sparkles").font(.caption)
                }
            }
            .foregroundStyle(Theme.accent)
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let c = snapshot.categories
        return ChangeHistory.Category.allCases.compactMap { cat in
            c[cat].map { "\(String(localized: String.LocalizationValue(cat.rawValue))) \($0)" }
        }.joined(separator: " · ")
    }
}

/// The changes of one snapshot or of a time range, by kind: "nginx 1.24 → 1.26", added and removed entries,
/// config file diffs.
struct ChangesDetailView: View {
    let server: Server
    let title: String
    let command: String
    @Environment(Connections.self) private var connections
    @State private var files: [ChangeHistory.FileDiff]?
    @State private var error: String?
    @State private var investigatePrompt: String?

    private var stateFiles: [(ChangeHistory.Category, [ChangeHistory.Change])] {
        ChangeHistory.Category.allCases.filter { $0 != .config }.compactMap { cat in
            let changes = (files ?? []).filter { $0.category == cat }.flatMap(ChangeHistory.changes(in:))
            return changes.isEmpty ? nil : (cat, changes)
        }
    }

    private var configFiles: [ChangeHistory.FileDiff] { (files ?? []).filter { $0.category == .config } }

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let files {
                if files.isEmpty { Text("Nothing changed.").foregroundStyle(.secondary) }
                ForEach(stateFiles, id: \.0) { cat, changes in
                    Section(LocalizedStringKey(cat.rawValue)) {
                        ForEach(changes) { ChangeRow(change: $0) }
                    }
                }
                if !configFiles.isEmpty {
                    Section("Config files") {
                        ForEach(configFiles) { f in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(Array(f.removed.prefix(200).enumerated()), id: \.offset) { _, l in DiffLine(text: l, added: false) }
                                    ForEach(Array(f.added.prefix(200).enumerated()), id: \.offset) { _, l in DiffLine(text: l, added: true) }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("/" + f.path).font(.subheadline.monospaced()).lineLimit(1).truncationMode(.head)
                                    Text(f.isNew ? String(localized: "New file") : f.isDeleted ? String(localized: "Deleted")
                                         : "+\(f.added.count) −\(f.removed.count)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let files, !files.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button { investigatePrompt = prompt(files) } label: { Label("Explain", systemImage: "sparkle.magnifyingglass") }
                        .accessibilityIdentifier("history.explain")
                }
            }
        }
        .investigate(on: server, prompt: $investigatePrompt)
        .task { await load() }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            files = ChangeHistory.parseDiff(try await conn.run(command, timeout: .seconds(60)).stdout)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func prompt(_ files: [ChangeHistory.FileDiff]) -> String {
        """
        These changes happened on this server (\(title)):

        \(ChangeHistory.summary(files))

        Explain in plain words what changed and why it might have, whether any of it could cause problems \
        (security, broken services, config mistakes), and what I should check. Don't change anything.
        """
    }
}

private struct ChangeRow: View {
    let change: ChangeHistory.Change

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).font(.caption.weight(.bold)).frame(width: 14)
            Text(change.key).font(.subheadline.monospaced()).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Group {
                switch change.kind {
                case .changed: Text("\(change.old ?? "") → \(change.new ?? "")")
                case .added: Text(change.new ?? "")
                case .removed: Text(change.old ?? "").strikethrough()
                }
            }
            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch change.kind { case .added: "plus"; case .removed: "minus"; case .changed: "arrow.right" }
    }
    private var color: Color {
        switch change.kind { case .added: .green; case .removed: .red; case .changed: Theme.accent }
    }
}

private struct DiffLine: View {
    let text: String
    let added: Bool
    var body: some View {
        Text((added ? "+ " : "- ") + text)
            .font(.caption2.monospaced())
            .foregroundStyle(added ? Color.green : Color.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background((added ? Color.green : Color.red).opacity(0.08))
    }
}

private struct SincePicker: View {
    let pick: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date().addingTimeInterval(-86_400)

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Since", selection: $date, in: ...Date()).datePickerStyle(.graphical)
            }
            .navigationTitle("What changed since…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Show") { pick(date); dismiss() } }
            }
        }
    }
}
