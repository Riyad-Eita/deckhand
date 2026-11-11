import DeckhandCore
import SwiftUI

/// A read-only scan of a server you don't know yet: the map, the risks, a handover document.
struct ServerXrayView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var report: ServerXray.Report?
    @State private var changes: [String] = []
    @State private var scanning = false
    @State private var error: String?
    @State private var savedNotes = false
    @State private var investigatePrompt: String?

    private var storeKey: String { "xray.\(server.id.uuidString)" }

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let r = report {
                Section {
                    LabeledContent("System", value: r.os.isEmpty ? r.kernel : r.os)
                    LabeledContent("Size", value: String(localized: "\(r.cpus) CPU · \(ByteFormat.kb(Int64(r.memoryMB) * 1024)) memory"))
                    if r.diskTotalKB > 0 {
                        LabeledContent("Disk", value: "\(r.diskUsedKB * 100 / r.diskTotalKB) % · \(ByteFormat.kb(Int64(r.diskTotalKB)))")
                    }
                } header: {
                    Text("Scanned \(r.date.formatted(date: .abbreviated, time: .shortened))")
                }
                if !changes.isEmpty {
                    Section("Since the last scan") {
                        ForEach(changes, id: \.self) { Text($0).font(.footnote.monospaced()) }
                    }
                }
                let risks = r.risks
                Section {
                    if risks.isEmpty { Label("No risks found", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                    ForEach(risks) { risk in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: risk.level == .high ? "exclamationmark.octagon.fill" : risk.level == .medium ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                .foregroundStyle(risk.level == .high ? .red : risk.level == .medium ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(risk.title).font(.subheadline.weight(.semibold))
                                Text(risk.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: { Text("Risks") }
                if !r.sites.isEmpty {
                    Section {
                        ForEach(Array(r.sites.enumerated()), id: \.offset) { _, site in FlowRow(site: site, app: r.app(for: site)) }
                    } header: { Text("How requests flow") }
                }
                if !r.databases.isEmpty {
                    Section("Databases") {
                        ForEach(r.databases, id: \.port.port) { db in
                            LabeledContent(db.kind, value: "\(db.port.address):\(db.port.port)\(db.port.isPublic ? " · " + String(localized: "public") : "")")
                        }
                    }
                }
                if !r.containers.isEmpty {
                    Section("Containers") {
                        ForEach(r.containers, id: \.name) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack { Circle().fill(c.running ? .green : .secondary).frame(width: 8, height: 8); Text(c.name).font(.subheadline.weight(.medium)) }
                                Text("\(c.image) · \(c.status)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                Section("Backups") {
                    if r.hasBackups {
                        Label(r.backupTools.isEmpty ? String(localized: "A backup cron job") : r.backupTools.joined(separator: ", "), systemImage: "externaldrive.fill.badge.checkmark")
                    } else {
                        Label("None found", systemImage: "externaldrive.badge.xmark").foregroundStyle(.red)
                    }
                }
                if !r.cron.isEmpty {
                    Section("Cron jobs") { ForEach(r.cron.prefix(20), id: \.self) { Text($0).font(.caption.monospaced()).lineLimit(2) } }
                }
                if !r.certificates.isEmpty {
                    Section("Certificates") {
                        ForEach(r.certificates.sorted { $0.key < $1.key }, id: \.key) { d, end in
                            LabeledContent(d) { Text(end, format: .relative(presentation: .named)) }
                        }
                    }
                }
                Section {
                    Button { Task { await saveNotes(r) } } label: {
                        Label(savedNotes ? String(localized: "Saved to server notes") : String(localized: "Save to server notes"),
                              systemImage: savedNotes ? "checkmark" : "note.text.badge.plus")
                    }
                    .disabled(savedNotes)
                    .accessibilityIdentifier("xray.notes")
                    ShareLink(item: ServerXray.markdown(r, serverName: server.displayName)) {
                        Label("Share handover document", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        investigatePrompt = """
                        Here is a scan of this server:

                        \(ServerXray.markdown(r, serverName: server.displayName))

                        Look into the risks, highest first. Explain each in plain words and suggest the safest fix. Don't change anything yet.
                        """
                    } label: { Label("Go through the risks with an agent", systemImage: "sparkle.magnifyingglass") }
                } footer: {
                    Text("Server notes are what Claude Code, Codex and your own-key agent read about this server.")
                }
            } else if !scanning {
                Section {
                    Label("Find out what runs on this server: sites and domains, how requests reach the apps, databases, containers, cron jobs, backups and certificates. Read-only, nothing changes.", systemImage: "rectangle.and.text.magnifyingglass")
                        .font(.subheadline)
                    Button("Scan this server") { Task { await scan() } }
                        .accessibilityIdentifier("xray.scan")
                }
            }
            if scanning {
                HStack(spacing: 10) { ProgressView(); Text("Scanning …").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Server X-ray")
        .toolbar {
            if report != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await scan() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(scanning).accessibilityLabel("Scan again")
                }
            }
        }
        .investigate(on: server, prompt: $investigatePrompt)
        .onAppear {
            if report == nil, let data = UserDefaults.standard.data(forKey: storeKey) {
                report = try? JSONDecoder().decode(ServerXray.Report.self, from: data)
            }
        }
    }

    private func scan() async {
        scanning = true
        defer { scanning = false }
        do {
            let conn = try await connections.connection(for: server)
            let out = try await conn.run(ServerXray.probeCommand, timeout: .seconds(90)).stdout
            let domains = ServerXray.parse(out).domains
            let certs = domains.isEmpty ? "" : (try? await conn.run(ServerXray.certCommand(domains), timeout: .seconds(60)).stdout) ?? ""
            let new = ServerXray.parse(out, certificates: certs)
            changes = report.map { ServerXray.changes(from: $0, to: new) } ?? []
            report = new
            savedNotes = false
            error = nil
            if let data = try? JSONEncoder().encode(new) { UserDefaults.standard.set(data, forKey: storeKey) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveNotes(_ r: ServerXray.Report) async {
        do {
            let conn = try await connections.connection(for: server)
            let res = try await conn.run(ServerXray.saveToNotesCommand(ServerXray.markdown(r, serverName: server.displayName)), timeout: .seconds(20))
            savedNotes = res.stdout.contains("@@ok")
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// domain → web server → app, as one row.
private struct FlowRow: View {
    let site: ServerXray.Site
    let app: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: site.tls ? "lock.fill" : "lock.open").font(.caption).foregroundStyle(site.tls ? .green : .orange)
                Text(site.names.first ?? String(localized: "Default site")).font(.subheadline.weight(.semibold)).lineLimit(1)
                if site.names.count > 1 { Text("+\(site.names.count - 1)").font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 6) {
                Text(site.server).padding(.horizontal, 8).padding(.vertical, 3).background(Theme.accent.opacity(0.12), in: Capsule())
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                Text(app ?? "—").lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(app?.contains("nothing listening") == true ? .red : .primary)
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}
