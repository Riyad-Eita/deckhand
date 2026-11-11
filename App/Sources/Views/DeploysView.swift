import DeckhandCore
import SwiftUI

/// Apps deployed from Git to this server: deploy, auto-deploy on push, releases with one-tap rollback, logs.
struct DeploysView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var apps: [Deploys.Status]?
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let apps {
                Section {
                    if apps.isEmpty {
                        Text("Deploy an app from a Git repository: Deckhand fetches it, builds it, starts it, checks it answers, and keeps the last releases so you can roll back.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(apps) { s in
                        NavigationLink { AppDetailView(server: server, name: s.app.name) } label: {
                            HStack(spacing: 12) {
                                Circle().fill(s.running ? .green : .secondary.opacity(0.4)).frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.app.name).font(.body.weight(.medium))
                                    Text("\(s.app.branch) · \(s.liveCommit ?? String(localized: "not deployed"))").font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if s.deploying { ProgressView() }
                            }
                        }
                        .accessibilityIdentifier("app.\(s.app.name)")
                    }
                }
                Section { Button { adding = true } label: { Label("New app", systemImage: "plus") }.accessibilityIdentifier("apps.new") }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Deploys")
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $adding) { NewAppSheet(server: server) { Task { await load() } } }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            apps = Deploys.parseStatus(try await conn.run(Deploys.statusCommand, timeout: .seconds(30)).stdout)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct NewAppSheet: View {
    let server: Server
    let saved: () -> Void
    @Environment(Connections.self) private var connections
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var app = Deploys.App(name: "", repo: "")
    @State private var deployKey: String?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let error { ProblemView(message: error, compact: true) }
                Section {
                    TextField("name (e.g. shop)", text: $app.name).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("newapp.name")
                    TextField("git@github.com:me/shop.git", text: $app.repo).textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout.monospaced())
                        .accessibilityIdentifier("newapp.repo")
                    TextField("Branch", text: $app.branch).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Repository") } footer: {
                    if let deployKey {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("For a private repository, add this server's key as a read-only deploy key (GitHub: repository → Settings → Deploy keys):")
                            Text(deployKey).font(.caption2.monospaced()).textSelection(.enabled)
                            Button("Copy key") { UIPasteboard.general.string = deployKey }.font(.caption)
                        }
                    } else {
                        Button("Private repository? Show this server's deploy key") { Task { await loadKey() } }.font(.caption)
                    }
                }
                Section {
                    Menu("Use a preset") {
                        ForEach(Deploys.Preset.all) { p in Button(p.name) { app.build = p.build; app.start = p.start } }
                    }
                    TextField("Build command (optional)", text: $app.build, axis: .vertical).font(.callout.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Start command", text: $app.start, axis: .vertical).font(.callout.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("newapp.start")
                    TextField("Health URL, e.g. http://127.0.0.1:3000/", text: $app.health).font(.callout.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("newapp.health")
                } header: { Text("Build and run") } footer: {
                    Text("The start command runs in the release folder and keeps running in the background. If the health URL doesn't answer within 30 seconds, the previous release comes back by itself.")
                }
                Section {
                    Stepper("Keep \(app.keep) releases", value: $app.keep, in: 1...20)
                    Toggle("Deploy when I push", isOn: $app.autoDeploy).accessibilityIdentifier("newapp.auto")
                } footer: { Text("The server checks the branch every minute — no webhook or open port needed.") }
            }
            .navigationTitle("New app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Deploy") { Task { await save() } }
                        .disabled(busy || !Deploys.App.isValidName(app.name) || app.repo.isEmpty || app.branch.isEmpty)
                        .accessibilityIdentifier("newapp.deploy")
                }
            }
        }
    }

    private func loadKey() async {
        do {
            let conn = try await connections.connection(for: server)
            deployKey = try await conn.run(Deploys.deployKeyCommand, timeout: .seconds(30)).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            let conn = try await connections.connection(for: server)
            let out = try await conn.run(Deploys.saveCommand(app, topic: settings.ntfyTopicURL), timeout: .seconds(30)).stdout
            if out.contains("@@nogit") { error = String(localized: "This server has no git. Install it from Updates or the terminal."); return }
            _ = try await conn.run(Deploys.deployCommand(app.name), timeout: .seconds(20))
            saved(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct AppDetailView: View {
    let server: Server
    let name: String
    @Environment(Connections.self) private var connections
    @Environment(AppSettings.self) private var settings
    @State private var status: Deploys.Status?
    @State private var rollingTo: String?
    @State private var removing = false
    @State private var error: String?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let s = status {
                Section {
                    LabeledContent("Live commit", value: s.liveCommit ?? "—").font(.body.monospaced())
                    LabeledContent("Running", value: s.running ? String(localized: "yes") : String(localized: "no"))
                    if s.deploying { HStack(spacing: 10) { ProgressView(); Text("Deploying …") } }
                    Button { Task { await deploy() } } label: { Label("Deploy now", systemImage: "arrow.up.circle") }
                        .disabled(s.deploying).accessibilityIdentifier("app.deploy")
                    Toggle("Deploy when I push", isOn: Binding(get: { s.app.autoDeploy }, set: { v in Task { await setAuto(v) } }))
                } footer: { Text("\(s.app.repo) · \(s.app.branch)") }
                Section("Deploys") {
                    if s.deploys.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                    ForEach(s.deploys.prefix(15)) { d in
                        NavigationLink { LogView(server: server, title: d.sha, command: Deploys.logCommand(name, stamp: d.stamp)) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: icon(d.state)).foregroundStyle(color(d.state))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.message.isEmpty ? d.state : d.message).lineLimit(1)
                                    Text("\(d.sha) · \(d.date.formatted(date: .abbreviated, time: .shortened)) · \(label(d.state))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("deploy.\(d.state)")
                    }
                }
                Section {
                    ForEach(s.releases, id: \.self) { r in
                        HStack {
                            Text(r.split(separator: "-").last.map(String.init) ?? r).font(.callout.monospaced())
                            Text(r.split(separator: "-").prefix(2).joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if r == s.current { Text("live").font(.caption.weight(.semibold)).foregroundStyle(.green) }
                            else { Button("Roll back") { rollingTo = r }.buttonStyle(.borderless).accessibilityIdentifier("release.rollback") }
                        }
                    }
                } header: { Text("Releases") } footer: { Text("The last \(s.app.keep) releases are kept.") }
                Section {
                    NavigationLink { LogView(server: server, title: String(localized: "App log"), command: Deploys.appLogCommand(name)) } label: { Label("App log", systemImage: "text.alignleft") }
                    Button("Remove app", role: .destructive) { removing = true }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle(name)
        .task { await load(); while !Task.isCancelled { try? await Task.sleep(for: .seconds(3)); if status?.deploying == true { await load() } } }
        .refreshable { await load() }
        .confirmationDialog("Roll back to this release?", isPresented: Binding(get: { rollingTo != nil }, set: { if !$0 { rollingTo = nil } }), titleVisibility: .visible) {
            Button("Roll back") { if let r = rollingTo { Task { await rollback(r) } } }
        }
        .confirmationDialog("Remove \(name)?", isPresented: $removing, titleVisibility: .visible) {
            Button("Stop and remove", role: .destructive) { Task { await remove() } }
        } message: { Text("Stops the app and deletes its releases and logs on the server. The repository is not touched.") }
    }

    private func icon(_ s: String) -> String { s == "live" ? "checkmark.circle.fill" : s == "rollback" ? "arrow.uturn.backward.circle.fill" : s == "rolledback" ? "exclamationmark.arrow.circlepath" : "xmark.octagon.fill" }
    private func color(_ s: String) -> Color { s == "live" ? .green : s == "rollback" ? Theme.accent : s == "rolledback" ? .orange : .red }
    private func label(_ s: String) -> String {
        switch s {
        case "live": String(localized: "went live")
        case "rollback": String(localized: "rolled back by you")
        case "rolledback": String(localized: "failed the health check, rolled back")
        default: String(localized: "failed")
        }
    }

    private func run(_ c: String) async throws -> String { try await connections.connection(for: server).run(c, timeout: .seconds(60)).stdout }

    private func load() async {
        do { status = Deploys.parseStatus(try await run(Deploys.statusCommand)).first { $0.app.name == name }; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func deploy() async { _ = try? await run(Deploys.deployCommand(name)); try? await Task.sleep(for: .seconds(1)); await load() }
    private func setAuto(_ on: Bool) async {
        guard var a = status?.app else { return }
        a.autoDeploy = on
        _ = try? await run(Deploys.saveCommand(a, topic: settings.ntfyTopicURL)); await load()
    }
    private func rollback(_ r: String) async {
        do { let out = try await run(Deploys.rollbackCommand(name, release: r)); if !out.contains("@@ok") { error = out } ; try? await Task.sleep(for: .seconds(1)); await load() }
        catch { self.error = error.localizedDescription }
    }
    private func remove() async { _ = try? await run(Deploys.removeCommand(name)); status = nil; error = String(localized: "Removed.") }
}

/// A log file from the server.
private struct LogView: View {
    let server: Server
    let title: String
    let command: String
    @Environment(Connections.self) private var connections
    @State private var text: String?
    var body: some View {
        ScrollView {
            Text(text ?? "").font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .overlay { if text == nil { ProgressView() } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { text = (try? await connections.connection(for: server).run(command, timeout: .seconds(30)).stdout) ?? "" }
    }
}
