import DeckhandCore
import SwiftUI

/// Decoy files that push the moment someone opens them.
struct TripwireView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @Environment(AppSettings.self) private var settings
    @State private var root = RootRunner()
    @State private var status: Tripwire.Status?
    @State private var home = ""
    @State private var task: RootTask?
    @State private var error: String?

    struct RootTask: Identifiable { let id: String; let change: ConfigChange; let summary: String }

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let status {
                if status.active {
                    Section {
                        Label("Tripwires are armed", systemImage: "sensor.tag.radiowaves.forward.fill").foregroundStyle(.green)
                        ForEach(status.decoys, id: \.path) { d in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.title).font(.subheadline)
                                Text(d.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text("Leave these files alone. Backups that copy these folders will set them off too.")
                    }
                    Section("Alerts") {
                        if status.hits.isEmpty { Text("Nobody has touched them.").foregroundStyle(.secondary) }
                        ForEach(status.hits, id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
                    Section {
                        Button("Remove tripwires", role: .destructive) {
                            let change = Tripwire.disable(decoys: status.decoys.map(\.path))
                            task = RootTask(id: ConfigChange.makeID(title: change.title), change: change,
                                            summary: String(localized: "Removes the decoy files and stops the watcher."))
                        }
                    }
                } else {
                    Section {
                        Label("Plants decoy files where intruders look first: fake cloud keys, fake app secrets, a fake database backup and an old fake SSH key. The moment one is opened, you get an urgent push with who did it.", systemImage: "sensor.tag.radiowaves.forward")
                            .font(.subheadline)
                        ForEach(Tripwire.decoys(home: home.isEmpty ? "~" : home, user: server.username)) { d in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.title).font(.subheadline)
                                Text(d.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        Button("Plant tripwires") { plant() }
                            .disabled(home.isEmpty)
                            .accessibilityIdentifier("tripwire.plant")
                    } footer: {
                        Text("The decoys hold nothing real and open nothing. Pushes go to your ntfy topic.")
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Tripwires")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh")
            }
        }
        .sudoPassword(root, server: server)
        .sheet(item: $task) { t in
            RootTaskSheet(server: server, title: LocalizedStringKey(t.change.title), summary: LocalizedStringKey(t.summary),
                          files: t.change.files, script: t.change.script(id: t.id), steps: RootTaskSheet.changeSteps) { _ in
                Task { await load() }
            }
        }
        .task { await load() }
    }

    private func plant() {
        if settings.ntfyTopicURL.isEmpty { settings.ntfyTopicURL = TaskNotifier.newTopicURL() }
        guard let change = Tripwire.enable(topicURL: settings.ntfyTopicURL, decoys: Tripwire.decoys(home: home, user: server.username)) else { return }
        task = RootTask(id: ConfigChange.makeID(title: change.title), change: change,
                        summary: String(localized: "Writes four decoy files and starts a small watcher (python3) that pushes to \(settings.ntfyTopicURL) when one is opened."))
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            home = try await conn.run("printf '%s' \"$HOME\"", timeout: .seconds(10)).stdout
            if await root.run(Tripwire.statusScript, on: server) {
                status = Tripwire.parse(root.lines.joined(separator: "\n"))
                error = nil
            } else if root.phase != .idle {
                error = root.lines.last ?? String(localized: "Couldn't read the tripwires.")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
