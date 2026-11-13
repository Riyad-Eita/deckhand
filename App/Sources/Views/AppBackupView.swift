import DeckhandCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Move Deckhand to a new iPhone: an encrypted file with servers, connections, settings and (if chosen) secrets.
struct AppBackupView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Server.createdAt) private var servers: [Server]
    @Query private var connections: [ConnectionRecord]
    @State private var passphrase = ""
    @State private var repeatPassphrase = ""
    @State private var includeSecrets = false
    @State private var exported: URL?
    @State private var importing = false
    @State private var pendingImport: Data?
    @State private var importPassphrase = ""
    @State private var message: String?
    @State private var error: String?

    /// App settings worth carrying over (UserDefaults keys and prefixes).
    static let settingKeys = ["agent.hideSecrets", "agent.policy", "cli.access", "cli.claude.effort", "cli.claude.model", "cli.codex.effort",
                              "cli.codex.model", "lock.delay", "lock.enabled", "notify.ntfy", "provider.effort", "provider.kind", "terminal.keep"]
    static let settingPrefixes = ["provider.", "cli.", "incident.links", "rules."]

    var body: some View {
        Form {
            if let error { ProblemView(message: error, compact: true) }
            if let message { Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            Section {
                SecureField("Passphrase", text: $passphrase).accessibilityIdentifier("backup.app.pass")
                SecureField("Repeat passphrase", text: $repeatPassphrase).accessibilityIdentifier("backup.app.pass2")
                Toggle("Include passwords, keys and API keys", isOn: $includeSecrets)
                Button("Create backup file") {
                    Task {
                        if includeSecrets, KeyProtection.shared.enabled, await !KeyProtection.shared.unlock() { return }
                        export()
                    }
                }
                    .disabled(passphrase.count < 8 || passphrase != repeatPassphrase)
                    .accessibilityIdentifier("backup.app.export")
                if let exported {
                    ShareLink(item: exported) { Label("Share or save the file", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("backup.app.share")
                }
            } header: {
                Text("Export")
            } footer: {
                Text("\(servers.count) servers and \(connections.count) connections, encrypted with your passphrase (at least 8 characters). Without the passphrase the file can't be opened. Secrets are only included if you switch it on.")
            }
            Section {
                Button("Import a backup file") { importing = true }
                    .accessibilityIdentifier("backup.app.import")
            } header: {
                Text("Import")
            } footer: {
                Text("Adds the servers and connections that aren't here yet and takes over the settings.")
            }
        }
        .navigationTitle("Move to a new iPhone")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            pendingImport = try? Data(contentsOf: url)
            if pendingImport == nil { error = String(localized: "Couldn't read the file.") }
        }
        .alert("Passphrase", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil; importPassphrase = "" } })) {
            SecureField("Passphrase", text: $importPassphrase)
            Button("Import") { if let d = pendingImport { restore(d) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The passphrase you chose when you made the backup.")
        }
        #if DEBUG
        .task {
            // DECKHAND_SEED_IMPORT=<file in tmp>|<passphrase>: import without the file picker (UI tests).
            if let spec = ProcessInfo.processInfo.environment["DECKHAND_SEED_IMPORT"] {
                let p = spec.split(separator: "|", maxSplits: 1).map(String.init)
                if p.count == 2, let d = try? Data(contentsOf: FileManager.default.temporaryDirectory.appending(path: p[0])) {
                    importPassphrase = p[1]; restore(d)
                }
            }
        }
        #endif
    }

    private func secretAccounts() -> [String] {
        servers.flatMap { [$0.secretAccount, $0.secretAccount + ".passphrase", "backup.password.\($0.id.uuidString)"] }
            + connections.map(\.secretAccount)
            + ProviderKind.allCases.map { "apikey.\($0.rawValue)" }
    }

    private func export() {
        error = nil; message = nil
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        var settings: [String: JSONValue] = [:]
        for (k, v) in defaults where Self.settingKeys.contains(k) || Self.settingPrefixes.contains(where: { k.hasPrefix($0) }) {
            if let j = Self.json(v) { settings[k] = j }
        }
        var secrets: [String: String] = [:]
        if includeSecrets { for a in secretAccounts() { if let v = Keychain.get(a) { secrets[a] = v } } }
        let archive = AppArchive(
            servers: servers.map { .init(id: $0.id, name: $0.name, host: $0.host, port: $0.port, username: $0.username, authKind: $0.authKindRaw,
                                         pinnedHostKey: $0.pinnedHostKey, workingDirectory: $0.workingDirectory, recentDirectories: $0.recentDirectories) },
            connections: connections.map { .init(id: $0.id, name: $0.name, kind: $0.kind, url: $0.url, command: $0.command, enabled: $0.enabled) },
            settings: settings, secrets: secrets)
        do {
            let data = try archive.sealed(passphrase: passphrase)
            let name = "Deckhand backup \(Date().formatted(.iso8601.year().month().day())).deckhand"
            let url = FileManager.default.temporaryDirectory.appending(path: name)
            try data.write(to: url, options: .completeFileProtection)
            exported = url
            message = includeSecrets ? String(localized: "Backup file ready, with secrets.") : String(localized: "Backup file ready, without secrets.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restore(_ data: Data) {
        error = nil; message = nil
        do {
            let archive = try AppArchive.open(data, passphrase: importPassphrase)
            let have = Set(servers.map(\.id)), haveConn = Set(connections.map(\.id))
            var added = 0
            for s in archive.servers where !have.contains(s.id) {
                let server = Server(name: s.name, host: s.host, port: s.port, username: s.username, authKind: AuthKind(rawValue: s.authKind) ?? .key)
                server.id = s.id; server.pinnedHostKey = s.pinnedHostKey; server.workingDirectory = s.workingDirectory
                server.recentDirectories = s.recentDirectories
                context.insert(server); added += 1
            }
            for c in archive.connections where !haveConn.contains(c.id) {
                let r = ConnectionRecord(name: c.name, kind: c.kind, url: c.url, command: c.command)
                r.id = c.id; r.enabled = c.enabled
                context.insert(r)
            }
            for (k, v) in archive.settings { UserDefaults.standard.set(Self.plist(v), forKey: k) }
            for (a, v) in archive.secrets { Keychain.set(v, for: a) }
            try? context.save()
            message = String(localized: "Imported \(added) servers. Restart Deckhand to load the settings.")
        } catch {
            self.error = error.localizedDescription
        }
        pendingImport = nil; importPassphrase = ""
    }

    static func json(_ v: Any) -> JSONValue? {
        if let n = v as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue) }
        if let s = v as? String { return .string(s) }
        if let a = v as? [Any] { return .array(a.compactMap(json)) }
        if let d = v as? [String: Any] { return .object(d.compactMapValues(json)) }
        return nil
    }

    static func plist(_ v: JSONValue) -> Any? {
        switch v {
        case .bool(let b): b
        case .number(let n): n
        case .string(let s): s
        case .array(let a): a.compactMap(plist)
        case .object(let o): o.compactMapValues(plist)
        default: nil
        }
    }
}
