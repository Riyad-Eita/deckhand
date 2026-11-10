import DeckhandCore
import SwiftData
import SwiftUI

/// GitHub on one server: sign in with GitHub's own device page, git uses it, agents get GitHub's MCP tools.
struct GitHubSection: View {
    let server: Server
    /// Shows the sign-in sheet (presented by the parent screen — sheets from inside a list in a sheet are unreliable).
    let showSignIn: () -> Void
    /// Bumped by the parent when the sign-in sheet closes.
    let signInClosed: Int
    @Environment(\.modelContext) private var context
    @Query(sort: \ConnectionRecord.createdAt) private var records: [ConnectionRecord]
    @State private var state: GitHubConnect.State?
    @State private var busy = false
    @State private var confirmDisconnect = false
    @State private var message: String?

    var body: some View {
        Section {
            HStack(spacing: 12) {
                BrandIcon(brand: .github, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub")
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy || state == nil {
                    ProgressView()
                } else if case .signedIn? = state {
                    Button("Disconnect", role: .destructive) { confirmDisconnect = true }.buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button("Connect") { Task { await connect() } }.buttonStyle(.borderedProminent).controlSize(.small)
                        .accessibilityIdentifier("github.connect")
                }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } footer: {
            Text("Signs the GitHub CLI in on this server: git push and pull, gh and the agents can use GitHub right away. The agents also get GitHub's MCP tools.")
        }
        .task { await refresh() }
        .onChange(of: signInClosed) { Task { await finishSignIn() } }
        .confirmationDialog("Disconnect GitHub from \(server.displayName)?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await disconnect() } }
        } message: {
            Text("Signs the GitHub CLI out on the server, removes git's GitHub credentials there and the GitHub connection for the agents.")
        }
    }

    private var subtitle: String {
        switch state {
        case .signedIn(let account)?: String(localized: "Connected as \(account)")
        case .notInstalled?: String(localized: "GitHub CLI not installed yet")
        case .signedOut?: String(localized: "Not connected")
        case nil: String(localized: "Checking…")
        }
    }

    private func refresh() async {
        guard let conn = try? await Connections.shared.connection(for: server),
              let r = try? await conn.run(GitHubConnect.statusCommand, timeout: .seconds(20)) else { return }
        state = GitHubConnect.parseStatus(r.stdout)
    }

    private func connect() async {
        busy = true
        defer { busy = false }
        if state == .notInstalled {
            message = String(localized: "Installing the GitHub CLI…")
            guard let conn = try? await Connections.shared.connection(for: server),
                  let r = try? await conn.run(GitHubConnect.installCommand, timeout: .seconds(180)), r.exitCode == 0 else {
                message = String(localized: "Couldn't install the GitHub CLI on this server."); return
            }
            message = nil
        }
        showSignIn()
    }

    /// After the sheet closes: if signed in, give the agents GitHub's MCP server with the same token and sync it.
    private func finishSignIn() async {
        await refresh()
        guard case .signedIn? = state, let conn = try? await Connections.shared.connection(for: server),
              let token = try? await conn.run(GitHubConnect.tokenCommand, timeout: .seconds(20)).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return }
        let record = records.first { $0.url == GitHubConnect.mcpURL } ?? {
            let r = ConnectionRecord(name: "GitHub", kind: "http", url: GitHubConnect.mcpURL)
            context.insert(r)
            return r
        }()
        record.enabled = true
        Keychain.set(token, for: record.secretAccount)
        let enabled = records.filter(\.enabled).map { ($0.spec, $0.token) } + (records.contains(record) ? [] : [(record.spec, token)])
        _ = try? await conn.run(ConnectionSync.script(enabled), timeout: .seconds(180))
        message = String(localized: "Git, gh and the agents on this server can use GitHub now.")
    }

    private func disconnect() async {
        busy = true
        defer { busy = false }
        guard let conn = try? await Connections.shared.connection(for: server) else { return }
        _ = try? await conn.run(GitHubConnect.logoutCommand, timeout: .seconds(30))
        for r in records where r.url == GitHubConnect.mcpURL {
            Keychain.set(nil, for: r.secretAccount)
            context.delete(r)
        }
        let remaining = records.filter { $0.enabled && $0.url != GitHubConnect.mcpURL }.map { ($0.spec, $0.token) }
        _ = try? await conn.run(ConnectionSync.script(remaining), timeout: .seconds(180))
        message = String(localized: "GitHub is disconnected from this server.")
        await refresh()
    }
}

/// Runs `gh auth login` on the server and shows GitHub's device page with the code to enter.
struct GitHubLoginSheet: View {
    let server: Server
    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var failed: String?
    @State private var done = false
    @State private var task: Task<Void, Never>?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if done {
                    ContentUnavailableView("Connected", systemImage: "checkmark.circle.fill", description: Text("GitHub is set up on \(server.displayName)."))
                        .foregroundStyle(.green)
                } else if let failed {
                    ContentUnavailableView("Sign-in didn't work", systemImage: "xmark.octagon", description: Text(LocalizedStringKey(failed)))
                } else if let code {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enter this code on the page").font(.caption).foregroundStyle(.secondary)
                            Text(code).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                                .accessibilityIdentifier("github.code")
                        }
                        Spacer()
                        Button(copied ? "Copied" : "Copy") { UIPasteboard.general.string = code; copied = true }.buttonStyle(.borderedProminent)
                    }
                    .padding(14)
                    .background(.bar)
                    LoginWebView(url: GitHubConnect.deviceURL) { _ in }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Starting GitHub sign-in on \(server.displayName)…").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Connect GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(done ? "Done" : "Cancel") { task?.cancel(); dismiss() } }
            }
        }
        .task {
            task = Task {
                do {
                    let conn = try await Connections.shared.connection(for: server)
                    for try await line in conn.streamLines(GitHubConnect.loginCommand) {
                        switch GitHubConnect.event(line) {
                        case .code(let c)?: code = c
                        case .succeeded?:
                            done = true
                            try? await Task.sleep(for: .seconds(1))
                            dismiss()
                        case .failed(let m)?: failed = m
                        case nil: break
                        }
                    }
                } catch is CancellationError {
                } catch {
                    if !done { failed = error.localizedDescription }
                }
            }
        }
        .onDisappear { task?.cancel() }
    }
}
