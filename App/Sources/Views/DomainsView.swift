import DeckhandCore
import SwiftUI

/// Domains served by Caddy with automatic HTTPS: DNS check first, then a guarded change; certificate status per domain.
struct DomainsView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var root = RootRunner()
    @State private var caddy: String?
    @State private var domains: [Domains.Status]?
    @State private var adding = false
    @State private var task: Task?
    @State private var error: String?

    struct Task: Identifiable { let id: String; let change: ConfigChange; let summary: String }

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let domains {
                Section {
                    if domains.isEmpty {
                        Text("Point a domain at a service on this server — Caddy gets the HTTPS certificate and renews it.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(domains) { d in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: d.certificateEnd != nil ? "lock.fill" : "lock.open").foregroundStyle(d.certificateEnd != nil ? .green : .orange)
                                Text(d.domain.name).font(.body.weight(.medium))
                            }
                            Text("→ \(d.domain.upstream)\(d.upstreamOK ? "" : " · " + String(localized: "not answering"))").font(.caption.monospaced())
                                .foregroundStyle(d.upstreamOK ? Color.secondary : Color.red)
                            if let end = d.certificateEnd {
                                Text("\(d.issuer.isEmpty ? String(localized: "Certificate") : d.issuer) · \(String(localized: "valid until")) \(end.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("No certificate yet — Caddy keeps trying while DNS and ports 80/443 aren't reachable.").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .swipeActions {
                            Button("Remove") {
                                let c = Domains.removeChange(d.domain.name)
                                task = Task(id: ConfigChange.makeID(title: c.title), change: c, summary: String(localized: "Removes \(d.domain.name) from Caddy. The service behind it keeps running."))
                            }.tint(.red)
                        }
                        .accessibilityIdentifier("domain.\(d.domain.name)")
                    }
                } footer: {
                    if let caddy { Text("Caddy: \(caddy)") }
                }
                Section { Button { adding = true } label: { Label("Add a domain", systemImage: "plus") }.accessibilityIdentifier("domains.add") }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Domains")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { _Concurrency.Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh") } }
        .sudoPassword(root, server: server)
        .task { await load() }
        .sheet(isPresented: $adding) {
            AddDomainSheet(server: server) { d in
                let c = Domains.addChange(d)
                task = Task(id: ConfigChange.makeID(title: c.title), change: c,
                            summary: String(localized: "Installs Caddy if needed and serves \(d.name) from \(d.upstream) with HTTPS."))
            }
        }
        .sheet(item: $task) { t in
            RootTaskSheet(server: server, title: LocalizedStringKey(t.change.title), summary: LocalizedStringKey(t.summary),
                          files: t.change.files, script: t.change.script(id: t.id), steps: RootTaskSheet.changeSteps) { _ in
                _Concurrency.Task { try? await _Concurrency.Task.sleep(for: .seconds(2)); await load() }
            }
        }
    }

    private func load() async {
        if await root.run(Domains.statusCommand, on: server) {
            let s = Domains.parseStatus(root.lines.joined(separator: "\n"))
            caddy = s.caddy; domains = s.domains; error = nil
        } else if root.phase != .idle {
            error = root.lines.last ?? String(localized: "Couldn't read the domains.")
        }
    }
}

private struct AddDomainSheet: View {
    let server: Server
    let add: (Domains.Domain) -> Void
    @Environment(Connections.self) private var connections
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var upstream = "127.0.0.1:3000"
    @State private var internalTLS = false
    @State private var check: Domains.Check?
    @State private var checking = false
    @State private var error: String?

    private var valid: Bool { Domains.Domain.isValidName(name) && Domains.Domain.isValidUpstream(upstream) }

    var body: some View {
        NavigationStack {
            Form {
                if let error { ProblemView(message: error, compact: true) }
                Section {
                    TextField("app.example.com", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .onChange(of: name) { check = nil }
                        .accessibilityIdentifier("domain.name")
                    TextField("127.0.0.1:3000", text: $upstream).textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout.monospaced())
                        .accessibilityIdentifier("domain.upstream")
                    Toggle("Caddy's own certificate", isOn: $internalTLS).accessibilityIdentifier("domain.internal")
                } footer: {
                    Text("The service address on this server. Caddy's own certificate is for internal names and testing; browsers won't trust it.")
                }
                Section {
                    Button { Task { await runCheck() } } label: { HStack { Text("Check DNS and ports"); Spacer(); if checking { ProgressView() } } }
                        .disabled(!valid || checking).accessibilityIdentifier("domain.check")
                    if let c = check {
                        Label(c.dnsOK ? String(localized: "\(name) points at this server.")
                              : c.resolves.isEmpty ? String(localized: "\(name) doesn't resolve yet. Add an A record for \(c.publicIP ?? c.local.first ?? "this server").")
                              : String(localized: "\(name) points at \(c.resolves.joined(separator: ", ")), not at this server (\(c.publicIP ?? c.local.first ?? "?")).") ,
                              systemImage: c.dnsOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(c.dnsOK ? .green : .orange).font(.footnote)
                        if let other = c.conflict {
                            Label(String(localized: "\(other) already uses port 80 or 443. Stop it or put this domain into its config instead."), systemImage: "xmark.octagon.fill")
                                .foregroundStyle(.red).font(.footnote)
                        }
                    }
                } footer: {
                    Text("Let's Encrypt only issues a certificate when the domain points here and ports 80 and 443 are reachable.")
                }
            }
            .navigationTitle("Add a domain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add(.init(name: name, upstream: upstream, internalTLS: internalTLS)); dismiss() }
                        .disabled(!valid || check == nil || check?.conflict != nil || (!internalTLS && check?.dnsOK != true))
                        .accessibilityIdentifier("domain.save")
                }
            }
        }
    }

    private func runCheck() async {
        checking = true
        defer { checking = false }
        do {
            let conn = try await connections.connection(for: server)
            check = Domains.parseCheck(try await conn.run(Domains.checkCommand(name), timeout: .seconds(30)).stdout)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
