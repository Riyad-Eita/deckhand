import DeckhandCore
import SwiftUI

/// Every file the agent changed in this task, with diffs; undo one file or all of them.
struct FilesChangedView: View {
    let server: Server
    let thread: ChatThread
    @Environment(Connections.self) private var connections
    @State private var changes: [Checkpoints.FileChange]?
    @State private var confirmAll = false
    @State private var error: String?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let changes {
                if changes.isEmpty {
                    Text("Nothing changed in \(thread.workingDirectory) since this task began.").foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(changes) { c in
                            NavigationLink { DiffView(change: c) } label: {
                                HStack(spacing: 10) {
                                    Text(c.kind.rawValue).font(.caption.monospaced().weight(.bold)).frame(width: 18)
                                        .foregroundStyle(c.kind == .added ? .green : c.kind == .deleted ? .red : Theme.accent)
                                    Text(c.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text("+\(c.added) −\(c.removed)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions { Button("Undo") { Task { await undo([c.path]) } }.tint(.orange) }
                            .accessibilityIdentifier("change.\(c.path)")
                        }
                    } footer: {
                        Text("Compared with \(thread.workingDirectory) when this task began. Swipe a file to undo just that one.")
                    }
                    Section {
                        Button("Undo all changes", role: .destructive) { confirmAll = true }.accessibilityIdentifier("changes.undoAll")
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Changed files")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Undo every change of this task?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Undo all", role: .destructive) { Task { await undo([]) } }
        } message: { Text("Changed and deleted files come back as they were; new files are removed.") }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            changes = Checkpoints.parseChanges(try await conn.run(Checkpoints.changesCommand(task: thread.id.uuidString, folder: thread.workingDirectory), timeout: .seconds(60)).stdout)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func undo(_ paths: [String]) async {
        do {
            let conn = try await connections.connection(for: server)
            _ = try await conn.run(Checkpoints.undoCommand(task: thread.id.uuidString, folder: thread.workingDirectory, paths: paths), timeout: .seconds(60))
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

private struct DiffView: View {
    let change: Checkpoints.FileChange
    @State private var width: CGFloat = 0
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(change.diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line)).font(.caption.monospaced())
                        .foregroundStyle(line.hasPrefix("+") ? .green : line.hasPrefix("-") ? .red : line.hasPrefix("@@") ? Theme.accent : .primary)
                        .padding(.horizontal, 12).padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.hasPrefix("+") ? Color.green.opacity(0.08) : line.hasPrefix("-") ? Color.red.opacity(0.08) : .clear)
                }
            }
            // Line colors run the full width, also for lines shorter than the screen.
            .frame(minWidth: width, alignment: .leading)
            .padding(.vertical, 8)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle((change.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }
}
