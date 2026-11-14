import DeckhandCore
import SwiftData
import SwiftUI

/// Saved commands for a server (its own, then the ones for every server). Tap one to send it to the terminal.
struct SnippetsSheet: View {
    let server: Server
    /// Sends text to the terminal; `run` adds the return key.
    let send: (_ text: String, _ run: Bool) -> Void
    @State private var store = SnippetStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var editing: Snippet?
    @State private var filling: Snippet?

    private var shown: [Snippet] {
        let list = Snippet.forServer(server.id, in: store.snippets)
        guard !search.isEmpty else { return list }
        return list.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.command.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                if store.snippets.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No saved commands yet").font(.headline)
                            Text("Save the commands you type often. Write {{name}} where a value changes, or {{name:default}} with a default — Deckhand asks for it before sending. In a task, open a command's card and tap Save as snippet.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                ForEach(shown) { s in
                    Button { pick(s) } label: { SnippetRow(snippet: s, global: s.serverID == nil) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("snippet.\(s.title)")
                        .swipeActions {
                            Button("Delete", role: .destructive) { store.snippets.removeAll { $0.id == s.id } }
                            Button("Edit") { editing = s }.tint(.gray)
                        }
                        .contextMenu {
                            Button { send(s.command, false); store.used(s); dismiss() } label: { Label("Insert without filling in", systemImage: "text.insert") }
                            Button { editing = s } label: { Label("Edit", systemImage: "pencil") }
                        }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic))
            .navigationTitle("Snippets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = Snippet(title: "", command: "", serverID: server.id) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New snippet")
                        .accessibilityIdentifier("snippet.new")
                }
            }
            .sheet(item: $editing) { s in SnippetEditor(snippet: s, serverID: server.id, serverName: server.displayName) }
            .sheet(item: $filling) { s in
                SnippetFillSheet(snippet: s) { text, run in send(text, run); store.used(s); dismiss() }
            }
        }
    }

    private func pick(_ s: Snippet) {
        if s.placeholders.isEmpty {
            send(s.command, true); store.used(s); dismiss()
        } else {
            filling = s
        }
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let global: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            let sameAsCommand = snippet.title.isEmpty || snippet.title == snippet.command
            HStack(spacing: 6) {
                Text(sameAsCommand ? snippet.command : snippet.title)
                    .font(sameAsCommand ? Theme.mono : .body.weight(.medium)).lineLimit(2)
                if global { Image(systemName: "globe").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("All servers") }
            }
            if !sameAsCommand {
                Text(snippet.command).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Asks for the placeholders, shows the finished command, then inserts it or runs it.
struct SnippetFillSheet: View {
    let snippet: Snippet
    let send: (_ text: String, _ run: Bool) -> Void
    @State private var values: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(snippet.placeholders) { p in
                        LabeledContent(p.name) {
                            TextField(p.defaultValue.isEmpty ? p.name : p.defaultValue,
                                      text: Binding(get: { values[p.name] ?? "" }, set: { values[p.name] = $0 }))
                                .font(Theme.mono)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focused, equals: p.name)
                                .accessibilityIdentifier("snippet.value.\(p.name)")
                        }
                    }
                }
                Section("Command") {
                    Text(snippet.filled(values)).font(Theme.mono).textSelection(.enabled)
                        .accessibilityIdentifier("snippet.preview")
                }
                Section {
                    Button { send(snippet.filled(values), true); dismiss() } label: { Label("Run", systemImage: "return") }
                        .accessibilityIdentifier("snippet.run")
                    Button { send(snippet.filled(values), false); dismiss() } label: { Label("Insert, don't run", systemImage: "text.insert") }
                }
            }
            .navigationTitle(snippet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { focused = snippet.placeholders.first?.name }
        }
        .presentationDetents([.medium, .large])
    }
}

/// New or changed snippet: title, command, this server or all.
struct SnippetEditor: View {
    @State var snippet: Snippet
    /// The server it was opened from (nil: from somewhere without one — then it's for every server).
    var serverID: UUID?
    var serverName: String?
    @State private var store = SnippetStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var forThisServer = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $snippet.title).accessibilityIdentifier("snippet.title")
                    TextField("Command", text: $snippet.command, axis: .vertical)
                        .font(Theme.mono).lineLimit(2...8)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("snippet.command")
                } footer: {
                    Text("Write {{name}} where a value changes, or {{name:default}}. Deckhand asks for the values before sending.")
                }
                if let serverName, serverID != nil {
                    Section {
                        Toggle(String(localized: "Only for \(serverName)"), isOn: $forThisServer)
                    } footer: {
                        Text("Off: the snippet shows up on every server.")
                    }
                }
                if !snippet.placeholders.isEmpty {
                    Section("Asks for") {
                        Text(snippet.placeholders.map { $0.defaultValue.isEmpty ? $0.name : "\($0.name) = \($0.defaultValue)" }.joined(separator: ", "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(store.snippets.contains { $0.id == snippet.id } ? "Edit snippet" : "New snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var s = snippet
                        s.title = s.title.trimmingCharacters(in: .whitespaces).isEmpty ? Snippet.suggestedTitle(for: s.command) : s.title
                        s.serverID = forThisServer ? (snippet.serverID ?? serverID) : nil
                        store.upsert(s)
                        dismiss()
                    }
                    .disabled(snippet.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("snippet.save")
                }
            }
            .onAppear { forThisServer = snippet.serverID != nil }
        }
    }
}
