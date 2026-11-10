import DeckhandCore
import SwiftUI

/// Containers and compose stacks on one server.
struct DockerView: View {
    let server: Server
    enum Mode: String, CaseIterable, Identifiable { case containers = "Containers", compose = "Compose"; var id: String { rawValue } }

    @Environment(Connections.self) private var connections
    @State private var overview: Docker.Overview?
    @State private var mode: Mode = .containers
    @State private var error: String?
    @State private var composeRun: ComposeRun?

    struct ComposeRun: Identifiable { let id = UUID(); let project: ComposeProject; let action: ComposeAction }
    @State private var confirmCompose: ComposeRun?

    var body: some View {
        List {
            Section {
                Picker("View", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            if let overview {
                if !overview.installed {
                    ContentUnavailableView("Docker isn't installed", systemImage: "shippingbox", description: Text("Install Docker on this server to manage containers here."))
                } else if overview.permissionDenied {
                    Text("Your user can't talk to Docker. Add it to the docker group: sudo usermod -aG docker $USER (then log in again).")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if mode == .containers {
                    Section(header: Text("\(overview.containers.filter(\.isRunning).count) running · \(overview.containers.count) total")) {
                        ForEach(overview.containers) { c in
                            NavigationLink {
                                ContainerDetailView(server: server, container: c) { Task { await load() } }
                            } label: { ContainerRow(container: c) }
                        }
                    }
                } else {
                    Section {
                        ForEach(overview.projects) { p in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Circle().fill(p.isRunning ? Color.green : .secondary.opacity(0.4)).frame(width: 9, height: 9)
                                    Text(p.name).font(.body.weight(.semibold))
                                    Spacer()
                                    Text(p.status).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(p.configFiles.joined(separator: ", ")).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                                HStack(spacing: 8) {
                                    ForEach(ComposeAction.allCases, id: \.self) { a in
                                        Button(a.title) {
                                            let run = ComposeRun(project: p, action: a)
                                            if a.isDisruptive { confirmCompose = run } else { composeRun = run }
                                        }
                                        .buttonStyle(.bordered).controlSize(.small)
                                        .tint(a.isDisruptive ? .red : Theme.accent)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } footer: {
                        Text("Compose stacks found by docker compose ls.")
                    }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Docker")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("\(confirmCompose?.action.title ?? "") \(confirmCompose?.project.name ?? "")?",
                            isPresented: Binding(get: { confirmCompose != nil }, set: { if !$0 { confirmCompose = nil } }),
                            titleVisibility: .visible) {
            Button(confirmCompose?.action.title ?? "", role: .destructive) { composeRun = confirmCompose }
        }
        .sheet(item: $composeRun, onDismiss: { Task { await load() } }) { run in
            CommandOutputSheet(server: server, title: "\(run.action.title) \(run.project.name)",
                               command: Docker.composeCommand(run.action, project: run.project))
        }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            overview = Docker.parseOverview(try await conn.run(Docker.overviewCommand, timeout: .seconds(60)).stdout)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ContainerRow: View {
    let container: DockerContainer
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(container.isUnhealthy ? Color.red : container.isRunning ? .green : .secondary.opacity(0.4)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(container.name).font(.body.weight(.medium))
                    if !container.publicPorts.isEmpty {
                        Text("public").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Color.orange.opacity(0.15), in: Capsule())
                    }
                }
                Text(container.image).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(container.isRunning ? (container.cpu ?? "") : container.state).font(.caption).monospacedDigit()
                if let mem = container.memory { Text(mem.components(separatedBy: " / ").first ?? mem).font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}

struct ContainerDetailView: View {
    let server: Server
    @State var container: DockerContainer
    let changed: () -> Void

    init(server: Server, container: DockerContainer, changed: @escaping () -> Void) {
        self.server = server
        _container = State(initialValue: container)
        self.changed = changed
    }

    @Environment(Connections.self) private var connections
    @Environment(\.dismiss) private var dismiss
    @State private var logs = ""
    @State private var busy: ContainerAction?
    @State private var confirm: ContainerAction?
    @State private var message: String?
    @State private var following = false
    @State private var followTask: Task<Void, Never>?
    @State private var investigatePrompt: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Image", value: container.image)
                LabeledContent("Status", value: container.status)
                if !container.ports.isEmpty { LabeledContent("Ports") { Text(container.ports).font(Theme.monoSmall).multilineTextAlignment(.trailing) } }
                if let p = container.composeProject { LabeledContent("Compose", value: p) }
                if container.isUnhealthy {
                    Button {
                        investigatePrompt = "The Docker container \(container.name) (image \(container.image)) is \(container.status). Read its logs and configuration, find the cause and suggest a fix. Don't change anything yet — ask me first."
                    } label: { Label("Investigate with an agent", systemImage: "sparkle.magnifyingglass") }
                }
            }
            if !container.publicPorts.isEmpty {
                Section {
                    Label {
                        Text("\(container.publicPorts.joined(separator: ", ")) is published on all interfaces. Docker bypasses ufw, so this port is reachable from the internet even if your firewall blocks it. Bind it to 127.0.0.1 in the compose file if it should stay private.")
                            .font(.footnote)
                    } icon: { Image(systemName: "exclamationmark.shield").foregroundStyle(.orange) }
                }
            }
            Section("Actions") {
                HStack(spacing: 8) {
                    ForEach(ContainerAction.allCases, id: \.self) { action in
                        Button {
                            if action.isDisruptive { confirm = action } else { Task { await run(action) } }
                        } label: {
                            HStack(spacing: 4) {
                                if busy == action { ProgressView().controlSize(.mini) }
                                Text(action.title)
                            }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(action.isDisruptive ? .red : Theme.accent)
                        .disabled(busy != nil)
                    }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                ScrollView(.horizontal) {
                    Text(logs.isEmpty ? "No output." : logs).font(Theme.monoSmall).textSelection(.enabled).fixedSize()
                }
            } header: {
                HStack {
                    Text("Logs")
                    Spacer()
                    Button(following ? "Stop" : "Follow") { following ? stopFollow() : startFollow() }.font(.caption.weight(.semibold))
                }
            }
        }
        .navigationTitle(container.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadLogs() }
        .onDisappear { stopFollow() }
        .investigate(on: server, prompt: $investigatePrompt)
        .confirmationDialog("\(confirm?.title ?? "") \(container.name)?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button(confirm?.title ?? "", role: .destructive) { if let a = confirm { Task { await run(a) } } }
        } message: {
            Text(confirm == .remove ? "The container is deleted. Volumes stay." : "Anything using \(container.name) is interrupted.")
        }
    }

    private func run(_ action: ContainerAction) async {
        busy = action
        defer { busy = nil }
        do {
            let conn = try await connections.connection(for: server)
            let r = try await conn.run(Docker.actionCommand(action, container: container.name), timeout: .seconds(120))
            message = r.exitCode == 0 ? "\(action.title) done." : (r.stderr.isEmpty ? r.stdout : r.stderr)
            changed()
            if action == .remove && r.exitCode == 0 { dismiss() } else { await reloadContainer(); await loadLogs() }
        } catch {
            message = error.localizedDescription
        }
    }

    private func reloadContainer() async {
        guard let conn = try? await connections.connection(for: server),
              let r = try? await conn.run(Docker.overviewCommand, timeout: .seconds(60)),
              let fresh = Docker.parseOverview(r.stdout).containers.first(where: { $0.id == container.id || $0.name == container.name })
        else { return }
        container = fresh
    }

    private func loadLogs() async {
        guard let conn = try? await connections.connection(for: server),
              let r = try? await conn.run(Docker.logsCommand(container: container.name, lines: 200), timeout: .seconds(30)) else { return }
        logs = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startFollow() {
        following = true
        followTask = Task {
            guard let conn = try? await connections.connection(for: server) else { following = false; return }
            do {
                for try await line in conn.streamLines(Docker.followLogsCommand(container: container.name)) {
                    logs += (logs.isEmpty ? "" : "\n") + line
                    if logs.count > 200_000 { logs = String(logs.suffix(150_000)) }
                }
            } catch {}
            following = false
        }
    }

    private func stopFollow() {
        following = false
        followTask?.cancel()
        followTask = nil
    }
}

/// Runs one command and shows its output as it arrives.
struct CommandOutputSheet: View {
    let server: Server
    let title: String
    let command: String
    @Environment(\.dismiss) private var dismiss
    @Environment(Connections.self) private var connections
    @State private var output = ""
    @State private var running = true

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(output.isEmpty ? "…" : output).font(Theme.monoSmall).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { if running { ProgressView() } }
            }
        }
        .task {
            defer { running = false }
            guard let conn = try? await connections.connection(for: server) else { output = "Not connected."; return }
            do {
                for try await line in conn.streamLines(command) { output += line + "\n" }
                output += "\nDone."
            } catch {
                output += "\n" + error.localizedDescription
            }
        }
    }
}
