import DeckhandCore
import SwiftUI

/// Everything the agent did in this task: commands, files, searches — with times and results, and an export.
struct ActionLogView: View {
    let thread: ChatThread
    let server: Server
    @State private var open: Set<String> = []
    @Environment(AppSettings.self) private var settings

    /// Secrets masked as in the chat (export: always redacted — it leaves the device).
    private func shown(_ text: String) -> String { settings.hideSecrets ? Secrets.mask(text) : text }

    private var entries: [ActionLog.Entry] { ActionLog.entries(thread.messages) }

    var body: some View {
        let entries = entries
        let t = ActionLog.totals(entries)
        List {
            Section {
                HStack(spacing: 18) {
                    total("\(t.commands)", "Commands")
                    total("\(t.changedFiles)", "Files changed")
                    total("\(t.failed)", "Failed", tint: t.failed > 0 ? .red : nil)
                }
                if let first = t.first, let last = t.last {
                    Text("\(first.formatted(date: .abbreviated, time: .shortened)) – \(last.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if t.changedFiles > 0 {
                    NavigationLink { FilesChangedView(server: server, thread: thread) } label: { Label("Changed files with diffs", systemImage: "doc.badge.clock") }
                }
            }
            Section {
                if entries.isEmpty { Text("No actions yet.").foregroundStyle(.secondary) }
                ForEach(entries) { e in
                    Button {
                        if open.contains(e.id) { open.remove(e.id) } else { open.insert(e.id) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: e.kind.symbol).foregroundStyle(e.failed == true ? .red : e.kind.changes ? .orange : .secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(e.detail.isEmpty ? e.kind.rawValue : shown(e.detail)).font(Theme.mono).foregroundStyle(.primary)
                                    .lineLimit(open.contains(e.id) ? nil : 2)
                                HStack(spacing: 6) {
                                    if let d = e.date { Text(d.formatted(date: .omitted, time: .standard)) }
                                    if e.failed == true { Text("failed").foregroundStyle(.red) }
                                }
                                .font(.caption2).foregroundStyle(.secondary)
                                if open.contains(e.id), !e.output.isEmpty {
                                    Text(shown(e.output)).font(Theme.monoSmall).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("log.entry.\(e.kind.rawValue)")
                }
            } header: { Text("Actions") }
        }
        .navigationTitle("Action log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: Secrets.redact(ActionLog.markdown(title: thread.title, server: server.displayName, folder: thread.workingDirectory,
                                                                  engine: thread.engine.title, entries: entries)),
                          subject: Text(thread.title), preview: SharePreview("Action log: \(thread.title)")) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("log.export")
            }
        }
    }

    private func total(_ value: String, _ title: LocalizedStringKey, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(tint ?? .primary)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
