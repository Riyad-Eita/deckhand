import DeckhandCore
import SwiftUI

/// Real backups with restic: a wizard, the schedule, snapshots to browse and restore.
struct BackupsView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @Environment(AppSettings.self) private var settings
    @State private var status: Backups.Status?
    @State private var error: String?
    @State private var busy = false
    @State private var password: String?

    // Wizard
    @State private var suggestions: [String] = []
    @State private var chosen: Set<String> = []
    @State private var customPath = ""
    enum Kind: String, CaseIterable, Identifiable { case folder, sftp, s3; var id: String { rawValue } }
    @State private var kind: Kind = .s3
    @State private var folder = ""
    @State private var sftp = ""
    @State private var endpoint = "https://"
    @State private var bucket = ""
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var hour = 3
    @State private var keepDaily = 7
    @State private var keepWeekly = 4
    @State private var keepMonthly = 6

    private var keychainAccount: String { "backup.password.\(server.id.uuidString)" }

    var body: some View {
        List {
            // In the wizard the error shows next to the set-up button, where the user just tapped.
            if let error, status?.configured != false { ProblemView(message: error, compact: true) }
            if let status {
                if status.configured { overview(status) } else { wizard }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Backups")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh")
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: Binding(get: { password.map { PasswordNote(value: $0) } }, set: { password = $0?.value })) { note in
            PasswordSheet(password: note.value)
        }
    }

    struct PasswordNote: Identifiable { let value: String; var id: String { value } }

    // MARK: Wizard

    @ViewBuilder private var wizard: some View {
        Section {
            ForEach(suggestions, id: \.self) { p in
                Toggle(p, isOn: Binding(get: { chosen.contains(p) }, set: { if $0 { chosen.insert(p) } else { chosen.remove(p) } }))
                    .font(.callout.monospaced())
            }
            HStack {
                TextField("/srv/data", text: $customPath).font(.callout.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Add") {
                    let p = customPath.trimmingCharacters(in: .whitespaces)
                    if !p.isEmpty { suggestions.append(p); chosen.insert(p) }
                    customPath = ""
                }
            }
        } header: { Text("What to back up") } footer: {
            Text("Folders your login user can read. Databases are best backed up as dumps into one of these folders.")
        }
        Section {
            Picker("Where", selection: $kind) {
                Text("S3-compatible storage").tag(Kind.s3)
                Text("Another server (SFTP)").tag(Kind.sftp)
                Text("A folder on this server").tag(Kind.folder)
            }
            .accessibilityIdentifier("backup.kind")
            switch kind {
            case .s3:
                TextField("Endpoint (https://…)", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Bucket", text: $bucket).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Access key", text: $accessKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Secret key", text: $secretKey)
            case .sftp:
                TextField("user@host:/backups", text: $sftp).textInputAutocapitalization(.never).autocorrectionDisabled()
            case .folder:
                TextField("/mnt/backup", text: $folder).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("backup.folder")
            }
        } header: { Text("Where to") } footer: {
            switch kind {
            case .s3: Text("Works with Backblaze B2, Cloudflare R2, Wasabi, Hetzner, AWS S3 and others.")
            case .sftp: Text("The server logs in there with its own SSH key; add it to the other machine first.")
            case .folder: Text("Only protects against mistakes, not against a dead disk — unless it's another disk.")
            }
        }
        Section {
            Stepper("Every night at \(String(format: "%02d:00", hour))", value: $hour, in: 0...23)
            Stepper("Keep \(keepDaily) daily", value: $keepDaily, in: 1...60)
            Stepper("Keep \(keepWeekly) weekly", value: $keepWeekly, in: 0...52)
            Stepper("Keep \(keepMonthly) monthly", value: $keepMonthly, in: 0...36)
        } header: { Text("Schedule") } footer: {
            Text("Server time. Older snapshots are removed by these rules; a failed backup sends a push.")
        }
        Section {
            if let error { ProblemView(message: error, compact: true).accessibilityIdentifier("backup.error") }
            Button { Task { await setUp() } } label: {
                HStack { Text("Set up backups").font(.headline); Spacer(); if busy { ProgressView() } }
            }
            .disabled(busy || chosen.isEmpty || target == nil)
            .accessibilityIdentifier("backup.setup")
        } footer: {
            Text("Installs restic if needed (no root), creates an encrypted repository and schedules the nightly run.")
        }
    }

    private var target: Backups.Target? {
        switch kind {
        case .folder: let f = folder.trimmingCharacters(in: .whitespaces); return f.hasPrefix("/") ? .folder(f) : nil
        case .sftp: return sftp.contains("@") && sftp.contains(":") ? .sftp(sftp.trimmingCharacters(in: .whitespaces)) : nil
        case .s3:
            guard endpoint.hasPrefix("https://") || endpoint.hasPrefix("http://"), !bucket.isEmpty, !accessKey.isEmpty, !secretKey.isEmpty else { return nil }
            return .s3(endpoint: endpoint, bucket: bucket, accessKey: accessKey, secretKey: secretKey)
        }
    }

    // MARK: Overview

    @ViewBuilder private func overview(_ s: Backups.Status) -> some View {
        Section {
            if s.running {
                HStack(spacing: 10) { ProgressView(); Text("Backing up …") }
            } else if let run = s.lastRun {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.ok ? String(localized: "Last backup worked") : String(localized: "Last backup failed")).font(.subheadline.weight(.semibold))
                        Text(run.end, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: run.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(run.ok ? .green : .red) }
            } else {
                Text("No backup has run yet.").foregroundStyle(.secondary)
            }
            if let when = s.schedule { LabeledContent("Every night", value: String(format: "%02d:%02d", when.hour, when.minute)) }
            Button { Task { await runNow() } } label: { Label("Back up now", systemImage: "arrow.up.doc") }
                .disabled(busy || s.running)
                .accessibilityIdentifier("backup.now")
        }
        Section {
            if s.snapshots.isEmpty { Text(s.snapshotsError ? String(localized: "Couldn't read the repository.") : String(localized: "No snapshots yet.")).foregroundStyle(.secondary) }
            ForEach(s.snapshots) { snap in
                NavigationLink {
                    SnapshotBrowser(server: server, snapshot: snap, path: snap.paths.count == 1 ? snap.paths[0] : "/")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snap.time, format: .dateTime.day().month().year().hour().minute()).font(.subheadline)
                        HStack(spacing: 6) {
                            Text(snap.shortID).font(.caption.monospaced())
                            if let t = snap.totalBytes { Text("· \(ByteCountFormatter.string(fromByteCount: t, countStyle: .file))") }
                            if let a = snap.addedBytes { Text("· +\(ByteCountFormatter.string(fromByteCount: a, countStyle: .file))") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("backup.snapshot")
            }
        } header: { Text("Snapshots") }
        Section {
            LabeledContent("Repository", value: s.repository.hasPrefix("s3:") ? String(s.repository.dropFirst(3)) : s.repository)
            ForEach(s.paths, id: \.self) { Text($0).font(.caption.monospaced()) }
            LabeledContent("Keep", value: String(localized: "\(s.keep.daily) daily, \(s.keep.weekly) weekly, \(s.keep.monthly) monthly"))
            if let pw = Keychain.get(keychainAccount) {
                Button { password = pw } label: { Label("Show the repository password", systemImage: "key") }
            }
            Button("Stop backups", role: .destructive) { Task { await remove() } }
        } header: { Text("Settings") } footer: {
            Text("Stopping removes the schedule and the settings on the server. The snapshots stay in the repository.")
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            status = Backups.parseStatus(try await conn.run(Backups.statusCommand, timeout: .seconds(90)).stdout)
            if status?.configured == false, suggestions.isEmpty {
                suggestions = try await conn.run(Backups.suggestionsCommand, timeout: .seconds(15)).stdout.split(separator: "\n").map(String.init)
                if let home = suggestions.first { chosen = [home] }
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setUp() async {
        guard let target else { return }
        busy = true
        defer { busy = false }
        var plan = Backups.Plan(paths: suggestions.filter(chosen.contains), target: target, password: Backups.newPassword())
        plan.hour = hour; plan.keepDaily = keepDaily; plan.keepWeekly = keepWeekly; plan.keepMonthly = keepMonthly
        if settings.ntfyTopicURL.isEmpty { settings.ntfyTopicURL = TaskNotifier.newTopicURL() }
        plan.topic = settings.ntfyTopicURL
        do {
            let conn = try await connections.connection(for: server)
            let out = try await conn.run(Backups.setupCommand(plan), timeout: .seconds(240)).stdout
            if let failed = out.split(separator: "\n").first(where: { $0.hasPrefix("@@failed ") }) {
                error = String(failed.dropFirst(9)); return
            }
            guard out.contains("@@ok") else { error = String(localized: "Setting up backups didn't finish."); return }
            Keychain.set(plan.password, for: keychainAccount)
            if out.contains("@@init") { password = plan.password }
            _ = try await conn.run(Backups.runNowCommand, timeout: .seconds(20))
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runNow() async {
        busy = true
        defer { busy = false }
        do {
            let conn = try await connections.connection(for: server)
            _ = try await conn.run(Backups.runNowCommand, timeout: .seconds(20))
            try? await Task.sleep(for: .seconds(1))
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() async {
        do {
            let conn = try await connections.connection(for: server)
            _ = try await conn.run(Backups.removeCommand, timeout: .seconds(20))
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The new repository's password: shown once, to be kept somewhere safe.
private struct PasswordSheet: View {
    let password: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(password).font(.title3.monospaced()).textSelection(.enabled).accessibilityIdentifier("backup.password")
                    Button { UIPasteboard.general.string = password } label: { Label("Copy", systemImage: "doc.on.doc") }
                } footer: {
                    Text("Without this password nobody can read the backups — not even you. Keep it in your password manager. Deckhand also keeps it in this iPhone's keychain.")
                }
            }
            .navigationTitle("Backup password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("I've saved it") { dismiss() } } }
        }
    }
}

/// One folder of a snapshot; restore anything into a new folder.
struct SnapshotBrowser: View {
    let server: Server
    let snapshot: Backups.Snapshot
    let path: String
    @Environment(Connections.self) private var connections
    @State private var nodes: [Backups.Node]?
    @State private var error: String?
    @State private var restored: String?
    @State private var restoring: String?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let restored {
                Label("Restored to \(restored)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote)
            }
            if let nodes {
                if nodes.isEmpty { Text("Empty folder.").foregroundStyle(.secondary) }
                ForEach(nodes) { n in
                    Group {
                        if n.isDirectory {
                            NavigationLink { SnapshotBrowser(server: server, snapshot: snapshot, path: n.path) } label: { row(n) }
                        } else {
                            row(n)
                        }
                    }
                    .swipeActions { Button("Restore") { Task { await restore(n.path) } }.tint(Theme.accent) }
                    .contextMenu { Button { Task { await restore(n.path) } } label: { Label("Restore", systemImage: "arrow.uturn.backward") } }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle((path as NSString).lastPathComponent.isEmpty ? "/" : (path as NSString).lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await restore(path) } } label: {
                    if restoring == path { ProgressView() } else { Text("Restore all") }
                }
                .accessibilityIdentifier("backup.restoreAll")
            }
        }
        .task { await load() }
    }

    private func row(_ n: Backups.Node) -> some View {
        HStack {
            Image(systemName: n.isDirectory ? "folder.fill" : "doc").foregroundStyle(n.isDirectory ? Theme.accent : .secondary)
            Text(n.name).lineLimit(1)
            Spacer()
            if restoring == n.path { ProgressView() } else if let s = n.size { Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            nodes = Backups.parseList(try await conn.run(Backups.listCommand(snapshot: snapshot.id, path: path), timeout: .seconds(90)).stdout, parent: path)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restore(_ p: String) async {
        restoring = p
        defer { restoring = nil }
        do {
            let conn = try await connections.connection(for: server)
            let out = try await conn.run(Backups.restoreCommand(snapshot: snapshot.id, path: p), timeout: .seconds(600)).stdout
            if let line = out.split(separator: "\n").first(where: { $0.hasPrefix("@@restored ") }) { restored = String(line.dropFirst(11)) }
            else { error = out.split(separator: "\n").last.map(String.init) ?? String(localized: "Restore failed.") }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
