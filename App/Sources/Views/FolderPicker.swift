import DeckhandCore
import SwiftUI

/// Picks the folder a task works in by browsing the server over SSH.
struct FolderPicker: View {
    let server: Server
    let engine: Engine
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(Connections.self) private var connections
    @State private var path: String
    @State private var listing: DirectoryListing?
    @State private var error: String?
    @State private var loading = false

    init(server: Server, engine: Engine, onPick: @escaping (String) -> Void) {
        self.server = server
        self.engine = engine
        self.onPick = onPick
        _path = State(initialValue: server.recentDirectories.first ?? server.workingDirectory)
    }

    var body: some View {
        NavigationStack {
            List {
                if !server.recentDirectories.isEmpty && listing?.path == homePath {
                    Section("Recent") {
                        ForEach(server.recentDirectories, id: \.self) { dir in
                            Button { choose(dir) } label: {
                                Label(dir, systemImage: "clock").font(Theme.mono).foregroundStyle(.primary)
                            }
                        }
                    }
                }
                Section {
                    if let listing {
                        if listing.path != "/" {
                            Button { open(DirectoryListing.parent(of: listing.path)) } label: {
                                Label("..", systemImage: "arrow.turn.left.up").foregroundStyle(.primary)
                            }
                        }
                        ForEach(listing.folders, id: \.self) { name in
                            Button { open(DirectoryListing.join(listing.path, name)) } label: {
                                Label(name, systemImage: name.hasPrefix(".") ? "folder.badge.gearshape" : "folder")
                                    .foregroundStyle(name.hasPrefix(".") ? .secondary : .primary)
                            }
                        }
                        if listing.folders.isEmpty {
                            Text("No sub-folders").foregroundStyle(.secondary)
                        }
                    } else if let error {
                        ProblemView(message: error, compact: true)
                    } else {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(listing?.path ?? path).font(Theme.monoSmall).textCase(nil)
                        if listing?.isGitRepo == true {
                            Text("git").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.2), in: Capsule())
                        }
                    }
                }
            }
            .navigationTitle("Work in…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Folder") { if let p = listing?.path { choose(p) } }
                        .disabled(listing == nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let p = listing?.path {
                    Text("\(engine.title) will work in \(p)")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(.bar)
                }
            }
            .task(id: path) { await load() }
            .refreshable { await load() }
        }
        .hostKeyPrompt(inSheet: true)
    }

    @State private var homePath: String?

    private func open(_ newPath: String) { path = newPath }

    private func choose(_ dir: String) {
        var recents = server.recentDirectories.filter { $0 != dir }
        recents.insert(dir, at: 0)
        server.recentDirectories = Array(recents.prefix(6))
        onPick(dir)
        dismiss()
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let conn = try await connections.connection(for: server)
            let r = try await conn.run(DirectoryListing.command(path), timeout: .seconds(20))
            guard let l = DirectoryListing.parse(r.stdout) else {
                throw ToolError.failed(r.stderr.isEmpty ? "Can't open \(path)" : r.stderr)
            }
            if homePath == nil { homePath = l.path }
            listing = l
        } catch {
            listing = nil
            self.error = error.localizedDescription
        }
    }
}
