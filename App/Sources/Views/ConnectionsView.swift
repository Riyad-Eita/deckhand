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
                            HStack(spacing: 12) {
                                BrandIcon(brand: c.brand, fallback: "terminal", size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).foregroundStyle(.primary)
                                    Text(c.summary).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(get: { c.enabled }, set: { c.enabled = $0 })).labelsHidden()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
            ForEach(ConnectionPreset.Group.allCases, id: \.self) { group in
                Section(LocalizedStringKey(group == .custom ? "Your own" : "Add · \(group.rawValue)")) {
                    ForEach(ConnectionPreset.all.filter { $0.group == group }) { preset in
                        Button { adding = preset } label: {
                            RowLabel(title: preset.name, subtitle: preset.blurb) {
                                BrandIcon(brand: preset.brand, fallback: preset.symbol, size: 32)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("preset.\(preset.id)")
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
    enum Group: String, CaseIterable { case code = "Code", docs = "Docs", web = "Web", data = "Data", business = "Business", custom = "Your own" }
    let id: String
    let name: String
    let blurb: String
    let symbol: String
    let kind: String
    let url: String
    let command: String
    let needsToken: Bool
    let tokenHint: String
    var group: Group = .custom
    /// What the agent can do with it, and what it needs.
    var notes: String = ""
    /// Where to create the token.
    var tokenURL: String?

    var brand: Brand? {
        switch id {
        case "github": .github
        case "deepwiki", "context7", "url", "mslearn", "cfdocs", "hf": .mcp
        default: nil
        }
    }

    static let all: [ConnectionPreset] = [
        ConnectionPreset(
            id: "github", name: "GitHub", blurb: String(localized: "Issues, pull requests and code search for the agents."),
            symbol: "chevron.left.forwardslash.chevron.right", kind: "http", url: "https://api.githubcopilot.com/mcp/",
            command: "", needsToken: true, tokenHint: String(localized: "GitHub personal access token"), group: .code,
            notes: String(localized: "Read and open issues and pull requests, search code, look at Actions runs. Give the token only the repositories it needs."),
            tokenURL: "https://github.com/settings/personal-access-tokens/new"),
        ConnectionPreset(
            id: "hf", name: "Hugging Face", blurb: String(localized: "Models, datasets, Spaces and papers."),
            symbol: "face.smiling", kind: "http", url: "https://huggingface.co/mcp", command: "", needsToken: false,
            tokenHint: String(localized: "Access token (optional)"), group: .code,
            notes: String(localized: "Search and compare models and datasets. A read token raises the limits."),
            tokenURL: "https://huggingface.co/settings/tokens"),
        ConnectionPreset(
            id: "deepwiki", name: "DeepWiki", blurb: String(localized: "Ask questions about any public GitHub repository. No account needed."),
            symbol: "book", kind: "http", url: "https://mcp.deepwiki.com/mcp", command: "", needsToken: false, tokenHint: "", group: .docs,
            notes: String(localized: "Explains how a public project works, from its code and wiki.")),
        ConnectionPreset(
            id: "context7", name: "Context7", blurb: String(localized: "Up-to-date library documentation for coding."),
            symbol: "doc.text.magnifyingglass", kind: "http", url: "https://mcp.context7.com/mcp", command: "",
            needsToken: false, tokenHint: String(localized: "API key (optional)"), group: .docs,
            notes: String(localized: "Current docs and examples for thousands of libraries, so code fits the version you use.")),
        ConnectionPreset(
            id: "mslearn", name: "Microsoft Learn", blurb: String(localized: "Official docs for Azure, .NET and Microsoft 365."),
            symbol: "books.vertical", kind: "http", url: "https://learn.microsoft.com/api/mcp", command: "", needsToken: false, tokenHint: "",
            group: .docs, notes: String(localized: "Searches and reads Microsoft's documentation. No account needed.")),
        ConnectionPreset(
            id: "cfdocs", name: "Cloudflare Docs", blurb: String(localized: "Workers, DNS, Pages, R2 and the rest of Cloudflare."),
            symbol: "cloud", kind: "http", url: "https://docs.mcp.cloudflare.com/mcp", command: "", needsToken: false, tokenHint: "",
            group: .docs, notes: String(localized: "Searches Cloudflare's documentation. No account needed.")),
        ConnectionPreset(
            id: "awsdocs", name: "AWS Documentation", blurb: String(localized: "Search and read the AWS docs."),
            symbol: "server.rack", kind: "stdio", url: "", command: "uvx awslabs.aws-documentation-mcp-server@latest",
            needsToken: false, tokenHint: "", group: .docs,
            notes: String(localized: "Runs on your server and needs uv (Python).")),
        ConnectionPreset(
            id: "playwright", name: "Playwright", blurb: String(localized: "A browser the agent can drive."),
            symbol: "safari", kind: "stdio", url: "", command: "npx -y @playwright/mcp@latest --headless",
            needsToken: false, tokenHint: "", group: .web,
            notes: String(localized: "Opens pages, clicks, fills forms and takes snapshots — good for testing your own sites. Runs on your server and needs Node.js; the first start downloads a browser.")),
        ConnectionPreset(
            id: "fetch", name: "Fetch", blurb: String(localized: "Reads web pages as clean text."),
            symbol: "arrow.down.doc", kind: "stdio", url: "", command: "uvx mcp-server-fetch",
            needsToken: false, tokenHint: "", group: .web,
            notes: String(localized: "Turns a URL into Markdown for the agent. Runs on your server and needs uv (Python).")),
        ConnectionPreset(
            id: "filesystem", name: String(localized: "Files"), blurb: String(localized: "Read and write files in chosen folders."),
            symbol: "folder", kind: "stdio", url: "", command: "npx -y @modelcontextprotocol/server-filesystem /srv",
            needsToken: false, tokenHint: "", group: .data,
            notes: String(localized: "Only the folders at the end of the command are reachable. Mostly useful for the own-key agent; Claude Code and Codex can already work with files.")),
        ConnectionPreset(
            id: "postgres", name: "PostgreSQL", blurb: String(localized: "Read-only SQL on one database."),
            symbol: "cylinder.split.1x2", kind: "stdio", url: "", command: "npx -y @modelcontextprotocol/server-postgres postgresql://localhost/mydb",
            needsToken: false, tokenHint: "", group: .data,
            notes: String(localized: "Lets the agent look at tables and run read-only queries. Replace the connection string at the end. Runs on your server and needs Node.js.")),
        ConnectionPreset(
            id: "stripe", name: "Stripe", blurb: String(localized: "Customers, payments, subscriptions and refunds."),
            symbol: "creditcard", kind: "http", url: "https://mcp.stripe.com", command: "", needsToken: true,
            tokenHint: String(localized: "Restricted key (rk_…)"), group: .business,
            notes: String(localized: "Look up customers and payments and act on them. Use a restricted key with only the permissions you want the agent to have."),
            tokenURL: "https://dashboard.stripe.com/apikeys"),
        ConnectionPreset(
            id: "url", name: String(localized: "Other server (URL)"), blurb: String(localized: "Any MCP server with a streamable HTTP endpoint."),
            symbol: "link", kind: "http", url: "", command: "", needsToken: false, tokenHint: String(localized: "Bearer token (optional)")),
        ConnectionPreset(
            id: "command", name: String(localized: "Command on the server"), blurb: String(localized: "Starts a stdio MCP server on your server, e.g. with npx."),
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
                    if let notes = preset?.notes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(notes)
                            if let link = preset?.tokenURL.flatMap(URL.init(string:)) { Link("Create a token", destination: link) }
                        }
                    } else if kind == "stdio" {
                        Text("Runs on the server over SSH whenever an agent needs it.")
                    } else if preset?.id == "github" {
                        Text("Easier: open a server's tools and tap Connect next to GitHub — that signs in with your GitHub account and fills this in. Or create a token at github.com → Settings → Developer settings → Personal access tokens.")
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
