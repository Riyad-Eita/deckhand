import DeckhandCore
import SwiftData
import SwiftUI

/// What's on the server: Codex / Claude Code versions and logins, with install, update and login actions.
struct ServerToolsView: View {
    let server: Server
    /// Runs an interactive command in the server's terminal (used for logins).
    let runInTerminal: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(Connections.self) private var connections
    @State private var inventory: ServerInventory?
    @State private var error: String?
    @State private var busy: ServerCLI?
    @State private var installLog: String?
    @State private var signingIn: ServerCLI?
    @State private var githubSignIn = false
    @State private var githubClosed = 0

    var body: some View {
        NavigationStack {
            List {
                if let inventory {
                    Section {
                        ForEach(ServerCLI.allCases) { cli in
                            cliRow(cli, state: inventory.state(for: cli))
                        }
                    } header: {
                        Text("Coding agents")
                    } footer: {
                        Text("They run on the server with your own ChatGPT or Claude subscription. Updates install into your home folder, no root needed.")
                    }
                    GitHubSection(server: server, showSignIn: { githubSignIn = true }, signInClosed: githubClosed)
                    ConnectionSyncSection(server: server)
                    Section("Server") {
                        LabeledContent("System", value: inventory.os ?? "Unknown")
                        LabeledContent("Node.js", value: inventory.node ?? "Not installed")
                        LabeledContent("tmux", value: inventory.tmux ?? "Not installed")
                    }
                    if let installLog {
                        Section("Last install") {
                            Text(installLog).font(Theme.monoSmall).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                } else if let error {
                    VStack(spacing: 14) { Text("Could not read the server").font(.title3.weight(.semibold)); ProblemView(message: error) }.frame(maxWidth: .infinity).padding(.vertical, 30)
                } else {
                    HStack { Spacer(); ProgressView("Checking the server…"); Spacer() }
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Server Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh")
                        .disabled(busy != nil)
                }
            }
            .task { await refresh() }
            .sheet(isPresented: $githubSignIn, onDismiss: { githubClosed += 1 }) { GitHubLoginSheet(server: server) }
            .sheet(item: $signingIn) { cli in
                CLILoginView(server: server, cli: cli) { _ in Task { await refresh() } }
            }
        }
        .hostKeyPrompt(inSheet: true)
    }

    @ViewBuilder private func cliRow(_ cli: ServerCLI, state: ServerInventory.CLIState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                BrandIcon(brand: cli.brand, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cli.displayName).font(.headline)
                    Text(statusText(state)).font(.subheadline).foregroundStyle(statusColor(state))
                }
                Spacer()
                if busy == cli { ProgressView() }
            }
            HStack(spacing: 10) {
                Button(state.isInstalled ? "Update" : "Install") { Task { await install(cli) } }
                    .buttonStyle(.bordered)
                if state.isInstalled {
                    if state.loggedIn {
                        Button("Switch Account") { logIn(cli) }.buttonStyle(.bordered)
                    } else {
                        Button("Log In") { logIn(cli) }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .controlSize(.small)
            .disabled(busy != nil)
        }
        .padding(.vertical, 4)
    }

    private func logIn(_ cli: ServerCLI) {
        signingIn = cli
    }

    private func statusText(_ s: ServerInventory.CLIState) -> String {
        guard let version = s.version else { return "Not installed" }
        if s.loggedIn { return "\(version) · signed in" + (s.account.map { " (\($0))" } ?? "") }
        return "\(version) · not signed in"
    }

    private func statusColor(_ s: ServerInventory.CLIState) -> Color {
        !s.isInstalled ? .secondary : s.loggedIn ? .green : .orange
    }

    private func refresh() async {
        error = nil
        do {
            let conn = try await connections.connection(for: server)
            let r = try await conn.run(ServerInventory.probeCommand, timeout: .seconds(60))
            inventory = ServerInventory.parse(r.stdout)
            if let inventory { AgentStatus.shared.update(server, from: inventory) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func install(_ cli: ServerCLI) async {
        busy = cli
        defer { busy = nil }
        do {
            let conn = try await connections.connection(for: server)
            let r = try await conn.run(cli.installCommand, timeout: .seconds(900))
            let tail = (r.stdout + r.stderr).split(separator: "\n").suffix(6).joined(separator: "\n")
            installLog = r.exitCode == 0 ? "\(cli.displayName) is up to date.\n\(tail)" : "Install failed (exit \(r.exitCode)).\n\(tail)"
            await refresh()
        } catch {
            installLog = error.localizedDescription
        }
    }
}

/// Copies the app's MCP connections into the server's Claude Code and Codex.
private struct ConnectionSyncSection: View {
    let server: Server
    @Query(sort: \ConnectionRecord.createdAt) private var connections: [ConnectionRecord]
    @State private var syncing = false
    @State private var results: [String: [ServerCLI: Bool]]?
    @State private var error: String?

    var body: some View {
        Section {
            if connections.isEmpty {
                NavigationLink("Add connections") { ConnectionsView() }
            } else {
                Button {
                    Task { await sync() }
                } label: {
                    HStack {
                        Label("Sync \(connections.filter(\.enabled).count) connections", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if syncing { ProgressView() }
                    }
                }
                .disabled(syncing)
                if let results {
                    ForEach(results.keys.sorted(), id: \.self) { name in
                        HStack {
                            Text(name).font(Theme.mono)
                            Spacer()
                            ForEach(ServerCLI.allCases) { cli in
                                if let ok = results[name]?[cli] {
                                    Label(cli.displayName, systemImage: ok ? "checkmark.circle" : "xmark.circle")
                                        .font(.caption)
                                        .foregroundStyle(ok ? .green : .red)
                                }
                            }
                        }
                    }
                }
                if let error { ProblemView(message: error, compact: true) }
            }
        } header: {
            Text("Connections")
        } footer: {
            Text("Makes Codex and Claude Code on this server use the same MCP servers as the app. Tokens are stored in a private file in your home folder.")
        }
    }

    private func sync() async {
        syncing = true
        error = nil
        defer { syncing = false }
        do {
            let conn = try await Connections.shared.connection(for: server)
            let enabled = connections.filter(\.enabled).map { ($0.spec, $0.token) }
            let r = try await conn.run(ConnectionSync.script(enabled), timeout: .seconds(180))
            results = ConnectionSync.results(r.stdout)
            if enabled.isEmpty { results = [:] }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
