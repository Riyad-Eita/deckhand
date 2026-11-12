import DeckhandCore
import SwiftUI

/// One-tap app installs: what's installed (status, link, credentials, start/stop/update/remove) and the catalog.
struct AppInstallsView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var installed: [AppTemplates.Installed]?
    @State private var error: String?
    @State private var installing: AppTemplates.Template?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let installed, !installed.isEmpty {
                Section("Installed") {
                    ForEach(installed) { app in
                        NavigationLink { InstalledAppView(server: server, app: app) { Task { await load() } } } label: {
                            HStack(spacing: 12) {
                                TemplateIcon(symbol: app.template?.symbol ?? "shippingbox")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name).font(.body.weight(.medium))
                                    HStack(spacing: 5) {
                                        Circle().fill(app.running == app.total && app.total > 0 ? Color.green : app.running == 0 ? Color.red : Color.orange)
                                            .frame(width: 7, height: 7)
                                        Text(app.running == app.total && app.total > 0 ? String(localized: "Running")
                                             : app.running == 0 ? String(localized: "Stopped") : String(localized: "\(app.running) of \(app.total) running"))
                                        if let t = app.template { Text("· \(t.name)") }
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("apps.installed.\(app.name)")
                    }
                }
            }
            ForEach(AppTemplates.Category.allCases, id: \.self) { category in
                let items = AppTemplates.catalog.filter { $0.category == category }
                if !items.isEmpty {
                    Section(LocalizedStringKey(category.rawValue)) {
                        ForEach(items) { t in
                            Button { installing = t } label: {
                                HStack(spacing: 12) {
                                    TemplateIcon(symbol: t.symbol)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(t.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                        Text(LocalizedStringKey(t.summary)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle").foregroundStyle(Theme.accent)
                                }
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .accessibilityIdentifier("apps.template.\(t.id)")
                        }
                    }
                }
            }
            Section {} footer: {
                Text("Apps run with Docker Compose in ~/apps and listen on this server only. Open them through Deckhand, or give them a domain with HTTPS.")
            }
        }
        .navigationTitle("Install apps")
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $installing) { t in
            InstallAppSheet(server: server, template: t, taken: Set((installed ?? []).map(\.name))) { Task { await load() } }
        }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            installed = AppTemplates.parseList(try await conn.run(AppTemplates.listCommand, timeout: .seconds(30)).stdout)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct TemplateIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Theme.accent)
            .frame(width: 34, height: 34)
            .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Name and domain, then the install (image download can take minutes), then link and credentials. With a domain,
/// the guarded Caddy change follows.
private struct InstallAppSheet: View {
    let server: Server
    let template: AppTemplates.Template
    let taken: Set<String>
    let done: () -> Void
    @Environment(Connections.self) private var connections
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var domain = ""
    @State private var busy = false
    @State private var result: AppTemplates.InstallResult?
    @State private var error: String?
    @State private var domainTask: DomainTask?
    @State private var browsing: BrowserTarget?

    struct DomainTask: Identifiable { let id: String; let change: ConfigChange }

    private var slug: String { AppTemplates.slug(name.isEmpty ? template.id : name) }
    private var domainOK: Bool { domain.isEmpty ? !template.needsDomain : Domains.Domain.isValidName(domain.lowercased()) }
    private var valid: Bool { !slug.isEmpty && !taken.contains(slug) && domainOK }

    var body: some View {
        NavigationStack {
            Form {
                if let error { ProblemView(message: error, compact: true) }
                if let r = result, let port = r.port {
                    InstallResultView(template: template, name: slug, domain: domain.lowercased(), port: port, secrets: r.secrets, slow: r.slow) {
                        browsing = BrowserTarget(port: port)
                    }
                } else {
                    Section {
                        HStack(spacing: 12) {
                            TemplateIcon(symbol: template.symbol)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name).font(.headline)
                                Text(LocalizedStringKey(template.summary)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        TextField(template.id, text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("apps.name")
                        if template.isWeb {
                            TextField(template.needsDomain ? String(localized: "Domain (required)") : String(localized: "Domain (optional)"), text: $domain)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                .accessibilityIdentifier("apps.domain")
                        }
                    } footer: {
                        if taken.contains(slug) {
                            Text("An app named \(slug) is already installed.").foregroundStyle(.red)
                        } else if template.needsDomain {
                            Text("\(template.name) needs HTTPS: point a domain at this server first. Caddy gets the certificate.")
                        } else if template.isWeb {
                            Text("Without a domain the app is only reachable through Deckhand. With one, Caddy serves it with HTTPS.")
                        } else {
                            Text("Listens on 127.0.0.1 only; apps on this server connect with the connection string shown afterwards.")
                        }
                    }
                    Section {
                        Button { Task { await install() } } label: {
                            HStack { Text("Install").font(.headline); Spacer(); if busy { ProgressView() } }
                        }
                        .disabled(!valid || busy)
                        .accessibilityIdentifier("apps.install")
                    } footer: {
                        if busy { Text("Downloading and starting \(template.name). The first time this can take a few minutes.") }
                    }
                }
            }
            .navigationTitle(result == nil ? String(localized: "Install \(template.name)") : template.name)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(busy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if result == nil { Button("Cancel") { dismiss() }.disabled(busy) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if result != nil { Button("Done") { done(); dismiss() }.accessibilityIdentifier("apps.done") }
                }
            }
            .sheet(item: $domainTask) { t in
                RootTaskSheet(server: server, title: LocalizedStringKey(t.change.title),
                              summary: LocalizedStringKey(String(localized: "Serves \(domain.lowercased()) from \(template.name) with HTTPS (installs Caddy if needed).")),
                              files: t.change.files, script: t.change.script(id: t.id), steps: RootTaskSheet.changeSteps) { _ in }
            }
            .sheet(item: $browsing) { BrowserSheet(server: server, port: $0.port, path: $0.path) }
        }
    }

    private func install() async {
        busy = true
        defer { busy = false }
        do {
            let conn = try await connections.connection(for: server)
            let plan = AppTemplates.Plan(template: template, name: slug, domain: domain)
            let r = AppTemplates.parseInstall(try await conn.run(AppTemplates.installCommand(plan), timeout: .seconds(900)).stdout)
            if let f = r.failure { error = f; return }
            guard let port = r.port else { error = String(localized: "The install didn't finish."); return }
            result = r
            error = nil
            if !plan.domain.isEmpty {
                let c = Domains.addChange(.init(name: plan.domain, upstream: "127.0.0.1:\(port)"))
                domainTask = DomainTask(id: ConfigChange.makeID(title: c.title), change: c)
            }
        } catch { self.error = error.localizedDescription }
    }
}

/// Link, credentials (tap to copy) and first steps.
private struct InstallResultView: View {
    let template: AppTemplates.Template
    let name: String
    let domain: String
    let port: Int
    let secrets: [String: String]
    let slow: Bool
    let open: () -> Void

    var body: some View {
        Section {
            Label(slow ? String(localized: "\(template.name) is still starting.") : String(localized: "\(template.name) is running."),
                  systemImage: slow ? "hourglass" : "checkmark.circle.fill")
                .foregroundStyle(slow ? .orange : .green)
                .accessibilityIdentifier("apps.installed")
            if template.isWeb {
                if domain.isEmpty {
                    Button { open() } label: { Label("Open through Deckhand", systemImage: "safari") }
                        .accessibilityIdentifier("apps.open")
                } else {
                    Link(destination: URL(string: "https://\(domain)")!) { Label("https://\(domain)", systemImage: "safari") }
                }
            }
        } footer: {
            if !template.firstSteps.isEmpty { Text(LocalizedStringKey(template.firstSteps)) }
        }
        let env = secrets.merging(["PORT": "\(port)", "DOMAIN": domain, "URL": domain.isEmpty ? "http://localhost:\(port)" : "https://\(domain)"]) { a, _ in a }
        let creds = AppTemplates.credentials(template, env: env)
        if !creds.isEmpty {
            CredentialsSection(credentials: creds)
        }
    }
}

struct CredentialsSection: View {
    let credentials: [(label: String, value: String)]
    @State private var copied: String?

    var body: some View {
        Section {
            ForEach(credentials, id: \.label) { c in
                Button {
                    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: c.value]], options: [.expirationDate: Date().addingTimeInterval(120)])
                    copied = c.label
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(LocalizedStringKey(c.label)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: copied == c.label ? "checkmark" : "doc.on.doc").font(.caption).foregroundStyle(.secondary)
                        }
                        // One line: a wrapped secret gets a hyphen that looks like part of it. Copying gives the full value.
                        Text(verbatim: c.value).font(.callout.monospaced()).foregroundStyle(.primary)
                            .lineLimit(1).minimumScaleFactor(0.6).truncationMode(.middle)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("apps.credential.\(c.label)")
            }
        } header: {
            Text("Credentials")
        } footer: {
            Text("Tap to copy (cleared from the clipboard after two minutes). They're also in the app's .env file on the server.")
        }
    }
}

/// One installed app: open, credentials, start/stop/restart/update, remove.
private struct InstalledAppView: View {
    let server: Server
    let app: AppTemplates.Installed
    let changed: () -> Void
    @Environment(Connections.self) private var connections
    @Environment(\.dismiss) private var dismiss
    @State private var env: [String: String]?
    @State private var busy: AppTemplates.Action?
    @State private var error: String?
    @State private var confirmRemove = false
    @State private var browsing: BrowserTarget?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            Section {
                if let t = app.template, t.isWeb {
                    if app.domain.isEmpty, let port = app.port {
                        Button { browsing = BrowserTarget(port: port) } label: { Label("Open through Deckhand", systemImage: "safari") }
                    } else if !app.domain.isEmpty {
                        Link(destination: URL(string: "https://\(app.domain)")!) { Label("https://\(app.domain)", systemImage: "safari") }
                    }
                }
                if let port = app.port {
                    LabeledContent("Address on the server", value: "127.0.0.1:\(port)").font(.callout)
                }
                LabeledContent("Folder", value: "~/apps/\(app.name)").font(.callout)
            }
            if let t = app.template, let env {
                let creds = AppTemplates.credentials(t, env: env)
                if !creds.isEmpty { CredentialsSection(credentials: creds) }
            }
            Section {
                action(.start, "Start", "play")
                action(.stop, "Stop", "stop")
                action(.restart, "Restart", "arrow.clockwise")
                action(.update, "Update to the newest images", "arrow.down.circle")
            }
            Section {
                Button("Remove…", role: .destructive) { confirmRemove = true }.accessibilityIdentifier("apps.remove")
            } footer: {
                Text("Removing keeps the data unless you choose otherwise. Installing it again under the same name picks the data up again.")
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadEnv() }
        .confirmationDialog("Remove \(app.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove, keep the data") { Task { await run(.remove) } }
            Button("Remove with all its data", role: .destructive) { Task { await run(.removeWithData) } }
        } message: {
            Text("Its containers stop and are removed. A domain stays in Caddy until you remove it under Domains.")
        }
        .sheet(item: $browsing) { BrowserSheet(server: server, port: $0.port, path: $0.path) }
    }

    private func action(_ a: AppTemplates.Action, _ title: LocalizedStringKey, _ symbol: String) -> some View {
        Button { Task { await run(a) } } label: {
            HStack { Label(title, systemImage: symbol); Spacer(); if busy == a { ProgressView() } }
        }
        .disabled(busy != nil)
    }

    private func loadEnv() async {
        guard let conn = try? await connections.connection(for: server) else { return }
        env = AppTemplates.parseEnv((try? await conn.run(AppTemplates.secretsCommand(name: app.name), timeout: .seconds(20)).stdout) ?? "")
    }

    private func run(_ a: AppTemplates.Action) async {
        busy = a
        defer { busy = nil }
        do {
            let conn = try await connections.connection(for: server)
            let out = try await conn.run(AppTemplates.actionCommand(a, name: app.name), timeout: .seconds(600)).stdout
            if let failed = out.split(separator: "\n").first(where: { $0.hasPrefix("@@failed ") }) {
                error = String(failed.dropFirst(9)); return
            }
            error = nil
            changed()
            if a == .remove || a == .removeWithData { dismiss() }
        } catch { self.error = error.localizedDescription }
    }
}
