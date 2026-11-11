import DeckhandCore
import SwiftUI

/// Nightly database dumps with a test restore and a confirmed real restore.
struct DatabaseDumpsView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @Environment(AppSettings.self) private var settings
    @State private var status: DatabaseDumps.Status?
    @State private var found: [DatabaseDumps.Database]?
    @State private var chosen: Set<String> = []
    @State private var keepDays = 14
    @State private var hour = 2
    @State private var busy = false
    @State private var error: String?
    @State private var message: String?
    @State private var restoring: (job: DatabaseDumps.Job, dump: DatabaseDumps.Dump)?
    @State private var typed = ""
    @State private var editing = false

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let message { Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote) }
            if let status, !status.jobs.isEmpty, !editing { jobs(status) } else if found != nil { picker } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Database dumps")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh")
            }
        }
        .task { await load() }
        .alert("Restore over the live database?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil; typed = "" } })) {
            TextField(restoring?.job.database.name ?? "", text: $typed).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Restore", role: .destructive) {
                if let r = restoring { Task { await restore(r.job, r.dump) } }
            }
            .disabled(typed != restoring?.job.database.name)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything changed since \(restoring?.dump.date.formatted(date: .abbreviated, time: .shortened) ?? "") is lost. Type the database name to confirm. Run a test restore first if you haven't.")
        }
    }

    @ViewBuilder private var picker: some View {
        Section {
            if found?.isEmpty == true {
                Text("No databases found that your login user can reach. Postgres needs a role for this user, MySQL a ~/.my.cnf; Docker containers need access to Docker.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(found ?? []) { db in
                Toggle(isOn: Binding(get: { chosen.contains(db.id) }, set: { if $0 { chosen.insert(db.id) } else { chosen.remove(db.id) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(db.label)
                        Text(engineName(db)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("db.\(db.name)")
            }
        } header: { Text("Databases on this server") }
        Section {
            Stepper("Every night at \(String(format: "%02d:00", hour))", value: $hour, in: 0...23)
            Stepper("Keep \(keepDays) days", value: $keepDays, in: 1...90)
            Button { Task { await save() } } label: {
                HStack { Text(status?.jobs.isEmpty == false ? String(localized: "Save") : String(localized: "Start nightly dumps")).font(.headline); Spacer(); if busy { ProgressView() } }
            }
            .disabled(busy || chosen.isEmpty)
            .accessibilityIdentifier("db.save")
        } footer: {
            Text("Dumps go to ~/.deckhand/db/dumps. If Backups are set up, they upload them with everything else.")
        }
    }

    @ViewBuilder private func jobs(_ s: DatabaseDumps.Status) -> some View {
        Section {
            if let when = s.schedule { LabeledContent("Every night", value: String(format: "%02d:%02d", when.hour, when.minute)) }
            Button { Task { await dumpNow() } } label: { HStack { Label("Dump now", systemImage: "square.and.arrow.down"); Spacer(); if busy { ProgressView() } } }
                .disabled(busy)
            Button("Change databases") { editing = true; Task { await discover(preselect: s) } }
        }
        ForEach(s.jobs) { job in
            Section {
                if let run = job.lastRun {
                    Label(run.ok ? String(localized: "Last dump worked") : String(localized: "Last dump failed"), systemImage: run.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(run.ok ? .green : .red).font(.subheadline)
                }
                if job.dumps.isEmpty { Text("No dumps yet.").foregroundStyle(.secondary) }
                ForEach(job.dumps.prefix(10)) { d in
                    HStack {
                        Text(d.date, format: .dateTime.day().month().hour().minute())
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: d.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Restore") { restoring = (job, d) }.tint(.red)
                        Button("Test") { Task { await testRestore(job, d) } }.tint(Theme.accent)
                    }
                    .contextMenu {
                        Button { Task { await testRestore(job, d) } } label: { Label("Test restore", systemImage: "checkmark.shield") }
                        Button(role: .destructive) { restoring = (job, d) } label: { Label("Restore…", systemImage: "arrow.uturn.backward") }
                    }
                    .accessibilityIdentifier("db.dump")
                }
            } header: {
                Text("\(job.database.label) · \(engineName(job.database))")
            } footer: {
                Text("Kept for \(job.keepDays) days. Swipe a dump to test it or restore it.")
            }
        }
        Section {
            Button("Stop database dumps", role: .destructive) { Task { await stop() } }
        } footer: { Text("The dumps already made stay in ~/.deckhand/db/dumps until you delete them.") }
    }

    private func engineName(_ db: DatabaseDumps.Database) -> String {
        let e = switch db.engine { case .postgres: "PostgreSQL"; case .mysql: "MySQL / MariaDB"; case .sqlite: "SQLite" }
        return db.container.map { "\(e) · " + String(localized: "Docker \($0)") } ?? (db.engine == .sqlite ? "\(e) · \(db.location)" : e)
    }

    private func run(_ command: String, timeout: Int = 120) async throws -> String {
        let conn = try await connections.connection(for: server)
        return try await conn.run(command, timeout: .seconds(timeout)).stdout
    }

    private func load() async {
        do {
            let s = DatabaseDumps.parseStatus(try await run(DatabaseDumps.statusCommand, timeout: 30))
            status = s
            if s.jobs.isEmpty { await discover(preselect: nil) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func discover(preselect: DatabaseDumps.Status?) async {
        do {
            let dbs = DatabaseDumps.parseDiscovery(try await run(DatabaseDumps.discoverCommand, timeout: 90))
            found = dbs
            if let preselect {
                chosen = Set(preselect.jobs.map(\.database.id)); keepDays = preselect.jobs.first?.keepDays ?? keepDays
                hour = preselect.schedule?.hour ?? hour
            } else { chosen = Set(dbs.map(\.id)) }
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let existing = Dictionary((status?.jobs ?? []).map { ($0.database.id, $0.id) }, uniquingKeysWith: { a, _ in a })
        let jobs = (found ?? []).filter { chosen.contains($0.id) }.map { (id: existing[$0.id] ?? DatabaseDumps.newJobID(), db: $0, keep: keepDays) }
        if settings.ntfyTopicURL.isEmpty { settings.ntfyTopicURL = TaskNotifier.newTopicURL() }
        do {
            let out = try await run(DatabaseDumps.saveCommand(jobs, hour: hour, topic: settings.ntfyTopicURL), timeout: 600)
            message = out.contains("@@backups") ? String(localized: "Dumps are on, and your backups now include them.") : nil
            editing = false
            await load()
        } catch { self.error = error.localizedDescription }
    }

    private func dumpNow() async {
        busy = true
        defer { busy = false }
        do { _ = try await run("bash \"$HOME/.deckhand/db/run.sh\"", timeout: 600); await load() } catch { self.error = error.localizedDescription }
    }

    private func testRestore(_ job: DatabaseDumps.Job, _ dump: DatabaseDumps.Dump) async {
        message = nil
        do {
            let out = try await run(DatabaseDumps.testRestoreCommand(job.database, dump: dump.file), timeout: 600)
            if let failed = out.split(separator: "\n").first(where: { $0.hasPrefix("@@failed") }) {
                error = String(localized: "Test restore failed: \(String(failed.dropFirst(9)))")
            } else if let t = out.split(separator: "\n").first(where: { $0.hasPrefix("@@tables ") }).flatMap({ Int($0.dropFirst(9)) }) {
                error = nil
                message = String(localized: "Test restore worked: \(t) tables came back.")
            }
        } catch { self.error = error.localizedDescription }
    }

    private func restore(_ job: DatabaseDumps.Job, _ dump: DatabaseDumps.Dump) async {
        typed = ""
        do {
            let out = try await run(DatabaseDumps.restoreCommand(job.database, dump: dump.file), timeout: 900)
            if out.contains("@@restored") { error = nil; message = String(localized: "\(job.database.label) is back to \(dump.date.formatted(date: .abbreviated, time: .shortened)).") }
            else { error = out.split(separator: "\n").last.map(String.init) ?? String(localized: "Restore failed.") }
        } catch { self.error = error.localizedDescription }
    }

    private func stop() async {
        do { _ = try await run(DatabaseDumps.saveCommand([], hour: hour, topic: "") + "\nrm -f \"$HOME/.deckhand/db/jobs.tsv\" \"$HOME/.deckhand/db/run.sh\"", timeout: 60); status = nil; found = nil; await load() }
        catch { self.error = error.localizedDescription }
    }
}
