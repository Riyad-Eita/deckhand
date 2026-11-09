import DeckhandCore
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
                    ContentUnavailableView("Could not read the server", systemImage: "exclamationmark.triangle", description: Text(error))
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
        }
    }

    @ViewBuilder private func cliRow(_ cli: ServerCLI, state: ServerInventory.CLIState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
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
        dismiss()
        runInTerminal(cli.loginCommand)
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
