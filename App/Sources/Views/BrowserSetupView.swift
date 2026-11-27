import DeckhandCore
import DeckhandSSH
import SwiftUI

/// Whether chats on a server get the browser tools (set here, read by the chat).
enum BrowserAccess {
    private static func key(_ id: UUID) -> String { "browser.enabled.\(id.uuidString)" }
    static func isOn(_ server: Server) -> Bool { UserDefaults.standard.bool(forKey: key(server.id)) }
    static func set(_ on: Bool, for server: Server) { UserDefaults.standard.set(on, forKey: key(server.id)) }
    static func isSet(_ server: Server) -> Bool { UserDefaults.standard.object(forKey: key(server.id)) != nil }

    /// The browser as an MCP connection for a chat on `server` (stdio through the SSH connection).
    static func connection(for server: Server) -> MCPConnection? {
        guard isOn(server) else { return nil }
        return MCPConnection(id: server.id, name: "Browser", transport: .stdio(command: BrowserSetup.mcpCommand), enabled: true)
    }
}

/// A headless browser on the server for the agent: one-tap setup, a test screenshot, and a switch for chats.
struct BrowserSetupView: View {
    let server: Server
    private var connections: Connections { .shared }
    @State private var root = RootRunner()
    @State private var status: BrowserSetup.Status?
    @State private var step: String?
    @State private var error: String?
    @State private var enabled = false
    @State private var testURL = "https://example.com"
    @State private var shot: Data?
    @State private var shooting = false

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let s = status {
                stateSection(s)
                if s.works {
                    useSection
                    trySection
                    Section {
                        Button("Remove the browser", role: .destructive) { Task { await remove() } }
                            .disabled(step != nil)
                            .accessibilityIdentifier("browser.remove")
                    } footer: {
                        Text("Deletes Playwright and the browser from your home folder. Node.js stays.")
                    }
                } else {
                    setupSection(s)
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView("Checking the server…"); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Browser for the agent")
        .navigationBarTitleDisplayMode(.inline)
        .sudoPassword(root, server: server)
        .refreshable { await load() }
        .task {
            enabled = BrowserAccess.isOn(server)
            await load()
            #if DEBUG
            // DECKHAND_SEED_BROWSER_TRY=<url>: take the "Try it" screenshot right away (store screenshots).
            if let url = ProcessInfo.processInfo.environment["DECKHAND_SEED_BROWSER_TRY"], status?.works == true { testURL = url; await screenshot() }
            #endif
        }
    }

    // MARK: - Sections

    private func stateSection(_ s: BrowserSetup.Status) -> some View {
        Section {
            row("Node.js", s.node ?? String(localized: "Not installed"), ok: s.node != nil)
            row("Playwright", s.installed ? (s.version ?? String(localized: "Installed")) : String(localized: "Not installed"), ok: s.installed)
            row("Browser", s.works ? String(localized: "Works") : s.browserReady ? String(localized: "Downloaded") : String(localized: "Not downloaded"), ok: s.works)
            LabeledContent("Disk free", value: ByteCountFormatter.string(fromByteCount: Int64(s.diskFreeMB) * 1_048_576, countStyle: .file))
        } header: {
            Text("This server")
        }
        .accessibilityIdentifier("browser.state")
    }

    private func setupSection(_ s: BrowserSetup.Status) -> some View {
        Section {
            if !s.missingLibraries.isEmpty {
                Text("The browser needs a few system libraries: \(s.missingLibraries.prefix(4).joined(separator: ", "))\(s.missingLibraries.count > 4 ? "…" : ""). Installing them needs sudo.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { Task { await installLibraries() } } label: {
                    HStack { Text("Install the libraries").font(.headline); Spacer(); if step != nil { ProgressView() } }
                }
                .disabled(step != nil)
                .accessibilityIdentifier("browser.deps")
            } else {
                Button { Task { await install() } } label: {
                    HStack { Text("Set up the browser").font(.headline); Spacer(); if step != nil { ProgressView() } }
                }
                .disabled(step != nil || (1..<600).contains(s.diskFreeMB))
                .accessibilityIdentifier("browser.install")
                if (1..<600).contains(s.diskFreeMB) {
                    Text("Needs about 600 MB of free disk.").font(.caption).foregroundStyle(.red)
                }
            }
            if let step {
                Label(step, systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("browser.step")
            }
        } header: {
            Text("Setup")
        } footer: {
            Text("Installs Playwright and a headless Chromium into your home folder (Node.js too, if the server has none) — no root needed, about 400 MB. The browser only runs while the agent uses it, started through your SSH connection. Nothing listens on the network, and every chat starts with a fresh browser profile.")
        }
    }

    private var useSection: some View {
        Section {
            Toggle("Use in chats on this server", isOn: $enabled)
                .onChange(of: enabled) { _, on in BrowserAccess.set(on, for: server) }
                .accessibilityIdentifier("browser.enabled")
        } footer: {
            Text("The agent can open pages, click, fill in forms and take screenshots. Clicks and form input wait for your approval like other actions.")
        }
    }

    private var trySection: some View {
        Section {
            HStack {
                TextField("https://…", text: $testURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .font(Theme.monoSmall)
                    .accessibilityIdentifier("browser.url")
                Button { Task { await screenshot() } } label: {
                    if shooting { ProgressView() } else { Text("Screenshot") }
                }
                .disabled(shooting || testURL.isEmpty)
                .accessibilityIdentifier("browser.shoot")
            }
            if let shot, let image = UIImage(data: shot) {
                Image(uiImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline))
                    .accessibilityLabel("Screenshot of \(testURL)")
                    .accessibilityIdentifier("browser.shot")
            }
        } header: {
            Text("Try it")
        } footer: {
            Text("Opens the page in the browser on your server, as the agent would see it.")
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String, ok: Bool) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(value).foregroundStyle(.secondary)
                Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? .green : .secondary)
            }
        } label: { Text(title) }
    }

    // MARK: - Actions

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            status = BrowserSetup.parse(try await conn.run(BrowserSetup.statusCommand, timeout: .seconds(90)).stdout)
            error = nil
            // Set up before (e.g. from the terminal) and never switched here: on.
            if status?.works == true, !BrowserAccess.isSet(server) { enabled = true; BrowserAccess.set(true, for: server) }
        } catch { self.error = error.localizedDescription }
    }

    private func install() async {
        error = nil
        step = String(localized: "Starting…")
        var needsDeps = false, ok = false, last = ""
        do {
            let conn = try await connections.connection(for: server)
            let channel = try await conn.openChannel(BrowserSetup.installScript + " 2>&1; echo \"@@end $?\"")
            defer { channel.close() }
            for try await line in channel.lines {
                if line.hasPrefix("@@step ") { step = String(localized: "Installing \(String(line.dropFirst(7)))…") }
                else if line == "@@needsdeps" { needsDeps = true }
                else if line == "@@ok" { ok = true }
                else if line.hasPrefix("@@end") { break }
                else if !line.hasPrefix("@@"), !line.isEmpty { last = line }
            }
        } catch { self.error = error.localizedDescription }
        step = nil
        if !ok && !needsDeps && error == nil { error = last.isEmpty ? String(localized: "The browser couldn't be set up.") : last }
        await load()
        if status?.works == true { enabled = true; BrowserAccess.set(true, for: server) }
    }

    private func installLibraries() async {
        error = nil
        step = String(localized: "Installing the libraries…")
        let ok = await root.run(BrowserSetup.depsScript, on: server)
        step = nil
        if !ok, root.phase != .idle { error = root.lines.last(where: { !$0.hasPrefix("@@") }) ?? String(localized: "The libraries couldn't be installed.") }
        await load()
        if status?.works == true { enabled = true; BrowserAccess.set(true, for: server) }
    }

    private func screenshot() async {
        shooting = true; defer { shooting = false }
        var url = testURL.trimmingCharacters(in: .whitespaces)
        if !url.contains("://") { url = "https://" + url }
        do {
            let conn = try await connections.connection(for: server)
            let result = BrowserSetup.parseScreenshot(try await conn.run(BrowserSetup.screenshotCommand(url: url), timeout: .seconds(100)).stdout)
            shot = result.image
            error = result.error
        } catch { self.error = error.localizedDescription }
    }

    private func remove() async {
        step = String(localized: "Removing…")
        do {
            let conn = try await connections.connection(for: server)
            _ = try await conn.run(BrowserSetup.removeCommand, timeout: .seconds(60))
        } catch { self.error = error.localizedDescription }
        step = nil
        enabled = false; BrowserAccess.set(false, for: server)
        shot = nil
        await load()
    }
}
