import DeckhandCore
import SwiftUI

/// Small edits by hand: undo/redo, save only if nobody changed the file meanwhile, and save as root (as a reversible
/// change) when the login may not write it.
struct FileEditorView: View {
    let server: Server
    let path: String
    var onSaved: () -> Void = {}
    @Environment(Connections.self) private var connections
    @Environment(\.dismiss) private var dismiss
    @State private var root = RootRunner()
    @State private var text = ""
    @State private var saved = ""
    @State private var sha = ""
    @State private var history = EditHistory("")
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var conflict = false
    @State private var askRoot = false
    @State private var confirmDiscard = false
    @State private var savedNote = false

    private var name: String { (path as NSString).lastPathComponent }
    private var dirty: Bool { text != saved }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                } else {
                    TextEditor(text: $text)
                        .font(Theme.mono)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8)
                        .onChange(of: text) { _, t in history.record(t) }
                        .accessibilityIdentifier("editor.text")
                }
            }
            .safeAreaInset(edge: .top) {
                if let error { ProblemView(message: error, compact: true).padding(.horizontal).padding(.vertical, 6).background(.bar) }
                else if savedNote { Label("Saved", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green).padding(6) }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(dirty ? String(localized: "Cancel") : String(localized: "Done")) {
                        if dirty { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { if let t = history.undo() { text = t } } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!history.canUndo).accessibilityLabel("Undo").accessibilityIdentifier("editor.undo")
                    Button { if let t = history.redo() { text = t } } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(!history.canRedo).accessibilityLabel("Redo")
                    Button { Task { await save(expected: sha) } } label: {
                        if saving { ProgressView() } else { Text("Save").bold() }
                    }
                    .disabled(!dirty || saving)
                    .accessibilityIdentifier("editor.save")
                }
            }
            .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
            }
            .alert("Changed on the server", isPresented: $conflict) {
                Button("Overwrite", role: .destructive) { Task { await overwrite() } }
                Button("Reload and lose my edits") { Task { await load() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Someone else changed \(name) since you opened it. Overwriting replaces their change with yours.")
            }
            .alert("Save as root?", isPresented: $askRoot) {
                Button("Save as root") { Task { await saveAsRoot() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(server.username) may not write \(name). As root it's saved like other changes: with a backup you can roll back in Change history.")
            }
            .sudoPassword(root, server: server)
            .interactiveDismissDisabled(dirty)
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let conn = try await connections.connection(for: server)
            let r = try await conn.run(FileEditing.loadCommand(path), timeout: .seconds(30))
            guard let file = FileEditing.parseLoad(r.stdout) else { throw ToolError.failed(r.stderr.isEmpty ? "Can't read \(path)" : r.stderr) }
            text = file.content; saved = file.content; sha = file.sha
            history.reset(file.content)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func save(expected: String) async {
        saving = true
        defer { saving = false }
        do {
            let conn = try await connections.connection(for: server)
            let r = try await conn.run(FileEditing.saveCommand(path, content: text, expected: expected), timeout: .seconds(60))
            switch FileEditing.parseSave(stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode) {
            case .saved(let newSha): didSave(sha: newSha)
            case .changed: conflict = true
            case .failed(let message):
                if FileEditing.needsRoot(message) { askRoot = true } else { error = message.isEmpty ? String(localized: "Couldn't save the file.") : message }
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Takes the server's current fingerprint and saves over it.
    private func overwrite() async {
        guard let conn = try? await connections.connection(for: server),
              let current = FileEditing.parseLoad((try? await conn.run(FileEditing.loadCommand(path), timeout: .seconds(30)))?.stdout ?? "") else { return }
        await save(expected: current.sha)
    }

    private func saveAsRoot() async {
        saving = true
        defer { saving = false }
        let change = FileEditing.rootChange(path, content: text)
        if await root.run(change.script(id: ConfigChange.makeID(title: change.title)), on: server) {
            // Fingerprint of what's there now, for the next save.
            if let conn = try? await connections.connection(for: server),
               let file = FileEditing.parseLoad((try? await conn.run(FileEditing.loadCommand(path), timeout: .seconds(30)))?.stdout ?? "") {
                didSave(sha: file.sha)
            } else { didSave(sha: sha) }
        } else if root.phase != .idle {
            error = root.lines.last(where: { !$0.hasPrefix("@@") }) ?? String(localized: "Couldn't save the file.")
        }
    }

    private func didSave(sha newSha: String) {
        sha = newSha
        saved = text
        history.reset(text)
        error = nil
        savedNote = true
        onSaved()
        Task { try? await Task.sleep(for: .seconds(2)); savedNote = false }
    }
}
