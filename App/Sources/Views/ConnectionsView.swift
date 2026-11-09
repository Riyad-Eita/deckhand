import DeckhandCore
import DeckhandSSH
import SwiftData
import SwiftUI

/// One list of MCP servers for every engine: the in-app agent uses them directly,
/// Codex and Claude Code get them when you sync a server.
struct ConnectionsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ConnectionRecord.createdAt) private var connections: [ConnectionRecord]
    @State private var adding: ConnectionPreset?
    @State private var editing: ConnectionRecord?

    var body: some View {
        List {
            if !connections.isEmpty {
                Section {
                    ForEach(connections) { c in
                        Button { editing = c } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).foregroundStyle(.primary)
                                    Text(c.summary).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(get: { c.enabled }, set: { c.enabled = $0 })).labelsHidden()
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            Keychain.set(nil, for: connections[i].secretAccount)
                            context.delete(connections[i])
                        }
                    }
                } footer: {
                    Text("Your own-key agent uses enabled connections right away. For Codex and Claude Code, open a server's tools and tap Sync.")
                }
            }
            Section("Add") {
                ForEach(ConnectionPreset.all) { preset in
                    Button { adding = preset } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).foregroundStyle(.primary)
                                Text(preset.blurb).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: preset.symbol) }
                    }
                }
            }
        }
        .navigationTitle("Connections")
        .sheet(item: $adding) { ConnectionEditor(record: nil, preset: $0) }
        .sheet(item: $editing) { ConnectionEditor(record: $0, preset: nil) }
    }
}

struct ConnectionPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let blurb: String
    let symbol: String
    let kind: String
    let url: String
    let command: String
    let needsToken: Bool
    let tokenHint: String

    static let all: [ConnectionPreset] = [
        ConnectionPreset(
            id: "github", name: "GitHub", blurb: "Issues, pull requests and code search for the agents.",
            symbol: "chevron.left.forwardslash.chevron.right", kind: "http", url: "https://api.githubcopilot.com/mcp/",
            command: "", needsToken: true, tokenHint: "GitHub personal access token"),
        ConnectionPreset(
            id: "deepwiki", name: "DeepWiki", blurb: "Ask questions about any public GitHub repository. No account needed.",
            symbol: "book", kind: "http", url: "https://mcp.deepwiki.com/mcp", command: "", needsToken: false, tokenHint: ""),
        ConnectionPreset(
            id: "context7", name: "Context7", blurb: "Up-to-date library documentation for coding.",
            symbol: "doc.text.magnifyingglass", kind: "http", url: "https://mcp.context7.com/mcp", command: "",
            needsToken: false, tokenHint: "API key (optional)"),
        ConnectionPreset(
            id: "url", name: "Other server (URL)", blurb: "Any MCP server with a streamable HTTP endpoint.",
            symbol: "link", kind: "http", url: "", command: "", needsToken: false, tokenHint: "Bearer token (optional)"),
        ConnectionPreset(
            id: "command", name: "Command on the server", blurb: "Starts a stdio MCP server on your server, e.g. with npx.",
            symbol: "terminal", kind: "stdio", url: "", command: "", needsToken: false, tokenHint: ""),
    ]
}

struct ConnectionEditor: View {
    let record: ConnectionRecord?
    let preset: ConnectionPreset?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Server.createdAt) private var servers: [Server]
    @State private var name = ""
    @State private var kind = "http"
    @State private var url = ""
    @State private var command = ""
    @State private var token = ""
    @State private var loaded = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var testFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    if kind == "http" {
                        TextField("https://example.com/mcp", text: $url)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(Theme.mono)
                        SecureField(preset?.tokenHint.isEmpty == false ? preset!.tokenHint : "Bearer token (optional)", text: $token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        TextField("npx -y @modelcontextprotocol/server-filesystem ~", text: $command, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(Theme.mono)
                    }
                } footer: {
                    if kind == "stdio" {
                        Text("Runs on the server over SSH whenever an agent needs it.")
                    } else if preset?.id == "github" {
                        Text("Create a token at github.com → Settings → Developer settings → Personal access tokens. One-tap GitHub sign-in is coming.")
                    }
                }
                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(!isValid || testing)
                    if let testResult {
                        Text(testResult).font(.footnote).foregroundStyle(testFailed ? .red : .secondary)
                    }
                }
            }
            .navigationTitle(record == nil ? (preset?.name ?? "Connection") : "Edit Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(); dismiss() }.disabled(!isValid)
                }
            }
            .onAppear(perform: load)
        }
        .hostKeyPrompt(inSheet: true)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (kind == "http" ? URL(string: url)?.scheme?.hasPrefix("http") == true : !command.trimmingCharacters(in: .whitespaces).isEmpty)
            && (preset?.needsToken != true || !token.isEmpty)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let record {
            name = record.name; kind = record.kind; url = record.url; command = record.command; token = record.token ?? ""
        } else if let preset {
            name = preset.id == "url" || preset.id == "command" ? "" : preset.name
            kind = preset.kind; url = preset.url; command = preset.command
        }
    }

    private var draft: MCPConnection {
        MCPConnection(name: name, transport: kind == "stdio" ? .stdio(command: command) : .http(url: url))
    }

    private func save() {
        let target = record ?? ConnectionRecord(name: name, kind: kind)
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.kind = kind
        target.url = url.trimmingCharacters(in: .whitespaces)
        target.command = command.trimmingCharacters(in: .whitespaces)
        if record == nil { context.insert(target) }
        Keychain.set(token.isEmpty ? nil : token, for: target.secretAccount)
    }

    private func test() async {
        testing = true
        testResult = nil
        defer { testing = false }
        do {
            var ssh: SSHConnection?
            if kind == "stdio" {
                guard let first = servers.first else { throw MCPError("Add a server first; the command runs there.") }
                ssh = try await Connections.shared.connection(for: first)
            }
            let client = try await MCPConnector.client(for: draft, token: token, server: ssh)
            let tools = try await MCPConnector.withTimeout(seconds: 20) { try await client.tools() }
            await client.close()
            testFailed = false
            testResult = "\(tools.count) tools: " + tools.map { $0.name }.prefix(12).joined(separator: ", ")
        } catch {
            testFailed = true
            testResult = error.localizedDescription
        }
    }
}
