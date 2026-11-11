import DeckhandCore
import SwiftUI

/// The notes agents keep about this server — read them, fix them, clear them.
struct ServerMemoryView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var text = ""
    @State private var loaded = false
    @State private var saved = ""
    @State private var status: String?
    @State private var confirmDelete = false
    @FocusState private var editing: Bool

    var body: some View {
        List {
            Section {
                if loaded {
                    TextEditor(text: $text)
                        .font(Theme.monoSmall)
                        .frame(minHeight: 260)
                        .focused($editing)
                        .accessibilityIdentifier("memory.editor")
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("No notes yet. Agents add what they learn about this server here — or write your own.")
                                    .font(.subheadline).foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                            }
                        }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            } footer: {
                Text("Kept on the server in \(ServerMemory.path). Your own-key agent reads it every time and can add to it; Claude Code and Codex are pointed to it as well. Never put secrets here.")
            }
            if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            Section {
                Button("Clear all notes") { text = ""; Task { await save() } }.disabled(text.isEmpty)
                Button("Delete notes and stop using them", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle("Server notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { editing = false; Task { await save() } }.disabled(!loaded || text == saved)
                    .accessibilityIdentifier("memory.save")
            }
        }
        .task { await load() }
        .confirmationDialog("Delete the notes?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("The file is removed and Claude Code and Codex aren't pointed to it anymore.")
        }
    }

    private func load() async {
        guard let conn = try? await connections.connection(for: server),
              let r = try? await conn.run(ServerMemory.readCommand, timeout: .seconds(15)) else { status = String(localized: "Couldn't read the notes."); return }
        text = r.stdout
        saved = r.stdout
        loaded = true
    }

    private func save() async {
        guard let conn = try? await connections.connection(for: server) else { return }
        let r = try? await conn.run(ServerMemory.writeCommand(text), timeout: .seconds(15))
        guard r?.stdout.contains("@@ok") == true else { status = String(localized: "Couldn't save the notes."); return }
        _ = try? await conn.run(ServerMemory.connectCLIsCommand, timeout: .seconds(15))
        saved = text
        status = String(localized: "Saved.")
    }

    private func delete() async {
        guard let conn = try? await connections.connection(for: server) else { return }
        _ = try? await conn.run(ServerMemory.deleteCommand + "; " + ServerMemory.disconnectCLIsCommand, timeout: .seconds(15))
        text = ""; saved = ""
        status = String(localized: "Notes deleted.")
    }
}
