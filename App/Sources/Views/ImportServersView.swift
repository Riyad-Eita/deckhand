import DeckhandCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Servers from another SSH app: an `~/.ssh/config`, a CSV export and private key files (matched by IdentityFile
/// name), or pasted text. Duplicates are found; keys only go into this iPhone's Keychain.
struct ImportServersView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var existing: [Server]
    @State private var candidates: [HostImport.Candidate] = []
    @State private var keys: [String: String] = [:]
    @State private var chosen: Set<String> = []
    @State private var picking = false
    @State private var message: String?
    @State private var imported = false

    private func isDuplicate(_ c: HostImport.Candidate) -> Bool {
        HostImport.isDuplicate(c, of: existing.map { ($0.host, $0.port, $0.username) })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { picking = true } label: { Label("Choose files", systemImage: "doc.badge.plus") }
                        .accessibilityIdentifier("import.files")
                    Button { add(UIPasteboard.general.string ?? "", name: nil) } label: { Label("Paste from the clipboard", systemImage: "doc.on.clipboard") }
                        .accessibilityIdentifier("import.paste")
                } footer: {
                    Text("Your ~/.ssh/config, a CSV export (Termius and others) and the private key files it names — pick them together. Keys stay on this iPhone, in its Keychain.")
                }
                if let message { Section { Text(message).font(.subheadline) } }
                if !candidates.isEmpty {
                    Section {
                        ForEach(candidates) { c in
                            Button {
                                if chosen.contains(c.id) { chosen.remove(c.id) } else { chosen.insert(c.id) }
                            } label: { row(c) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("import.host.\(c.name)")
                        }
                    } header: {
                        Text("Found \(candidates.count)")
                    }
                }
            }
            .navigationTitle("Import servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(imported ? "Done" : "Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Import \(chosen.count)")) { importChosen() }
                        .disabled(chosen.isEmpty)
                        .accessibilityIdentifier("import.go")
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url), data.count < 2_000_000, let text = String(data: data, encoding: .utf8) else { continue }
                    add(text, name: url.lastPathComponent)
                }
            }
            #if DEBUG
            .onAppear {
                if let seeded = ProcessInfo.processInfo.environment["DECKHAND_SEED_IMPORT_TEXT"] { add(seeded, name: nil) }
            }
            #endif
        }
    }

    private func row(_ c: HostImport.Candidate) -> some View {
        HStack(spacing: 10) {
            Image(systemName: chosen.contains(c.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(chosen.contains(c.id) ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.body.weight(.medium))
                Text("\(c.user)@\(c.host)\(c.port == 22 ? "" : ":\(c.port)")").font(.caption.monospaced()).foregroundStyle(.secondary)
                if isDuplicate(c) {
                    Text("Already in Deckhand").font(.caption).foregroundStyle(.orange)
                } else if let f = c.identityFile {
                    Text(keys[f] != nil ? String(localized: "Key \(f) found") : String(localized: "Key \(f) not chosen — add it or sign in with a password later"))
                        .font(.caption).foregroundStyle(keys[f] != nil ? Color.green : Color.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    /// A config/CSV adds hosts; a private key file is kept for the hosts that name it.
    private func add(_ text: String, name: String?) {
        if HostImport.isPrivateKey(text) {
            if let name { keys[name] = text }
            message = String(localized: "Key \(name ?? "") added.")
            return
        }
        let found = HostImport.parse(text)
        guard !found.isEmpty else { message = String(localized: "No servers found in \(name ?? String(localized: "the clipboard"))."); return }
        for c in found where !candidates.contains(where: { $0.id == c.id }) {
            candidates.append(c)
            if !isDuplicate(c) { chosen.insert(c.id) }
        }
        message = nil
    }

    private func importChosen() {
        var withoutCredentials = 0
        var made: [(candidate: HostImport.Candidate, server: Server)] = []
        for c in candidates where chosen.contains(c.id) && !isDuplicate(c) {
            let key = c.identityFile.flatMap { keys[$0] }
            let server = Server(name: c.name == c.host ? "" : c.name, host: c.host, port: c.port, username: c.user,
                                authKind: key != nil ? .key : .password)
            context.insert(server)
            made.append((c, server))
            if let key { Keychain.set(key, for: server.secretAccount) } else { withoutCredentials += 1 }
        }
        // ProxyJump: link to the jump host among the imported and existing servers (by alias or address).
        let pool: [(name: String, server: Server)] = made.map { ($0.candidate.name, $0.server) } + existing.map { ($0.name, $0) }
        let keys = pool.map { (name: $0.name, host: $0.server.host, port: $0.server.port, user: $0.server.username) }
        for (c, server) in made {
            guard let jump = c.proxyJump, let i = HostImport.jumpTarget(jump, among: keys), pool[i].server !== server else { continue }
            server.jumpHostID = pool[i].server.id
        }
        try? context.save()
        if withoutCredentials > 0 {
            // Stay open so this is read: those servers still need a way to sign in.
            message = String(localized: "Imported. \(withoutCredentials) of them need a password or key — swipe a server on the home screen and tap Edit.")
            candidates = []; chosen = []; imported = true
        } else {
            dismiss()
        }
    }
}
