import DeckhandCore
import SwiftUI

/// Managed `.env` files of one server, kept with their history in this iPhone's Keychain.
@MainActor
enum VaultStore {
    static func account(_ server: Server) -> String { "vault.\(server.id.uuidString)" }
    static func load(_ server: Server) -> [EnvVault.File] {
        guard let s = Keychain.get(account(server)), let d = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([EnvVault.File].self, from: d)) ?? []
    }
    static func save(_ files: [EnvVault.File], for server: Server) {
        let json = (try? JSONEncoder().encode(files)).flatMap { String(data: $0, encoding: .utf8) }
        Keychain.set(files.isEmpty ? nil : json, for: account(server))
    }
}

struct EnvVaultView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var files: [EnvVault.File] = []
    @State private var serverHashes: [UUID: String?] = [:]
    @State private var newPath = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            Section {
                if files.isEmpty { Text("No files yet. Add an app's .env to keep it here.").foregroundStyle(.secondary) }
                ForEach($files) { $file in
                    NavigationLink {
                        EnvFileView(server: server, file: $file) { VaultStore.save(files, for: server); Task { await check() } }
                    } label: { row(file) }
                    .accessibilityIdentifier("vault.file.\(file.path)")
                }
                .onDelete { idx in files.remove(atOffsets: idx); VaultStore.save(files, for: server) }
            } footer: {
                Text("Encrypted in this iPhone's Keychain, with the last 30 versions. Written to the server as 0600 files over SFTP — the values never appear in a command line.")
            }
            Section {
                HStack {
                    TextField("~/shop/.env", text: $newPath).font(Theme.mono).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("vault.path")
                    Button("Add") { Task { await add() } }
                        .disabled(busy || !EnvVault.isValidPath(newPath.trimmingCharacters(in: .whitespaces)))
                        .accessibilityIdentifier("vault.add")
                }
            } header: {
                Text("Add a file")
            } footer: {
                Text("An existing file is read into the vault; a new one starts empty.")
            }
        }
        .navigationTitle("Environment files")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await check() }
        .task { files = VaultStore.load(server); await check() }
    }

    private func row(_ f: EnvVault.File) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(f.path).font(Theme.mono)
            HStack(spacing: 6) {
                Text("\(EnvVault.variables(EnvVault.parse(f.current?.content ?? "")).count) variables")
                switch serverHashes[f.id] {
                case .none: EmptyView()
                case .some(.none): Text("· missing on the server").foregroundStyle(.orange)
                case .some(.some(let h)) where h != f.lastKnownHash: Text("· changed on the server").foregroundStyle(.orange)
                default: Text("· in sync").foregroundStyle(.green)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Reads every file's hash on the server, to show drift.
    private func check() async {
        guard let conn = try? await connections.connection(for: server) else { return }
        for f in files {
            let r = EnvVault.parseRead((try? await conn.run(EnvVault.readCommand(f.path), timeout: .seconds(20)).stdout) ?? "")
            serverHashes[f.id] = r.exists && r.readable ? EnvVault.hash(r.content) : .some(nil)
        }
    }

    private func add() async {
        let path = newPath.trimmingCharacters(in: .whitespaces)
        guard !files.contains(where: { $0.path == path }) else { return }
        busy = true
        defer { busy = false }
        do {
            let conn = try await connections.connection(for: server)
            let r = EnvVault.parseRead(try await conn.run(EnvVault.readCommand(path), timeout: .seconds(20)).stdout)
            if r.exists && !r.readable { error = String(localized: "\(path) exists but your user can't read it."); return }
            files.append(EnvVault.File(path: path, versions: [.init(content: r.content, note: r.exists ? "Imported from the server" : "New file")],
                                       lastKnownHash: r.exists ? EnvVault.hash(r.content) : ""))
            VaultStore.save(files, for: server)
            newPath = ""; error = nil
            await check()
        } catch { self.error = error.localizedDescription }
    }
}

/// One file: its variables (masked until shown), edits, writing to the server, and the history to roll back to.
private struct EnvFileView: View {
    let server: Server
    @Binding var file: EnvVault.File
    let changed: () -> Void
    @Environment(Connections.self) private var connections
    @State private var lines: [EnvVault.Line] = []
    @State private var revealed: Set<String> = []
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var editing: (key: String, value: String)?
    @State private var confirmWrite = false
    @State private var writing = false
    @State private var error: String?
    @State private var note: String?

    private var dirty: Bool { EnvVault.serialize(lines) != (file.current?.content ?? "") && !(file.current?.content.isEmpty ?? true && lines.isEmpty) }

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let note { Section { Label(note, systemImage: "checkmark.circle.fill").foregroundStyle(.green) } }
            Section {
                ForEach(EnvVault.variables(lines), id: \.key) { v in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.key).font(Theme.mono.weight(.medium))
                            Text(revealed.contains(v.key) ? v.value : String(repeating: "•", count: min(max(v.value.count, 4), 16)))
                                .font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        }
                        Spacer()
                        Button { if revealed.contains(v.key) { revealed.remove(v.key) } else { revealed.insert(v.key) } } label: {
                            Image(systemName: revealed.contains(v.key) ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(revealed.contains(v.key) ? "Hide value" : "Show value")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = (v.key, v.value) }
                    .swipeActions { Button("Delete", role: .destructive) { lines = EnvVault.remove(v.key, from: lines) } }
                    .accessibilityIdentifier("vault.var.\(v.key)")
                }
                HStack {
                    TextField("NEW_KEY", text: $newKey).font(Theme.mono).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .accessibilityIdentifier("vault.newKey")
                    SecureField("value", text: $newValue).font(Theme.mono).accessibilityIdentifier("vault.newValue")
                    Button("Add") {
                        lines = EnvVault.set(newKey.trimmingCharacters(in: .whitespaces), newValue, in: lines)
                        newKey = ""; newValue = ""
                    }
                    .disabled(newKey.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil)
                    .accessibilityIdentifier("vault.addVar")
                }
            } header: {
                Text("Variables")
            }
            Section {
                Button { confirmWrite = true } label: {
                    HStack { Label("Write to the server", systemImage: "arrow.up.doc"); Spacer(); if writing { ProgressView() } }
                }
                .disabled(writing || !dirty)
                .accessibilityIdentifier("vault.write")
            } footer: {
                Text(dirty ? "Not written yet." : "This is what's on the server (as of the last write or import).")
            }
            Section("History") {
                ForEach(file.versions.reversed()) { v in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.note).font(.subheadline)
                            Text(v.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if v.id != file.current?.id {
                            Button("Restore") { lines = EnvVault.parse(v.content); note = nil }
                                .buttonStyle(.bordered).controlSize(.small)
                                .accessibilityIdentifier("vault.restore")
                        } else {
                            Text("Current").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle((file.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if lines.isEmpty { lines = EnvVault.parse(file.current?.content ?? "") } }
        .alert("Change \(editing?.key ?? "")", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("value", text: Binding(get: { editing?.value ?? "" }, set: { editing?.value = $0 }))
            Button("Save") { if let e = editing { lines = EnvVault.set(e.key, e.value, in: lines) }; editing = nil }
            Button("Cancel", role: .cancel) { editing = nil }
        }
        .confirmationDialog("Write \(file.path) on \(server.displayName)?", isPresented: $confirmWrite, titleVisibility: .visible) {
            Button("Write") { Task { await write() } }
        } message: {
            Text("The app using it may need a restart to pick it up. The previous file stays as .deckhand-prev next to it.")
        }
    }

    private func write() async {
        writing = true
        defer { writing = false }
        let text = EnvVault.serialize(lines)
        do {
            let conn = try await connections.connection(for: server)
            _ = try await conn.run(EnvVault.prepareStagingCommand, timeout: .seconds(20))
            let up = try await conn.upload(Data(text.utf8), named: "env-\(UUID().uuidString.prefix(8))", into: EnvVault.stagingDir,
                                           commandLineFallback: false) { _ in }
            let out = try await conn.run(EnvVault.installCommand(uploaded: up, path: file.path), timeout: .seconds(20)).stdout
            guard out.contains("@@ok") else { error = String(localized: "Couldn't put the file in place."); return }
            file.add(.init(content: text, note: String(localized: "Written to the server")))
            file.lastKnownHash = EnvVault.hash(text)
            changed()
            error = nil
            note = String(localized: "Written as 0600.")
        } catch { self.error = error.localizedDescription }
    }
}
