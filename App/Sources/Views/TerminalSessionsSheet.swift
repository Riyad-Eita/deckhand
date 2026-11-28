import DeckhandCore
import DeckhandSSH
import SwiftUI

/// The tmux and screen sessions on a server: open one in a new tab, start one, end one. Without tmux it offers to
/// install it — with sudo from the distribution, without root built into ~/.local.
struct TerminalSessionsSheet: View {
    let server: Server
    /// Tabs that show a session: the app's own tab number for "deckhand-N", or the session a tab was opened on.
    let openTabs: [Int: String]
    let open: (TerminalSessions.Session) -> Void
    private var connections: Connections { .shared }
    @Environment(\.dismiss) private var dismiss
    @State private var listing: TerminalSessions.Listing?
    @State private var error: String?
    @State private var ending: TerminalSessions.Session?
    @State private var naming = false
    @State private var newName = ""
    @State private var root = RootRunner()
    @State private var installStep: String?
    @State private var canSudo: Bool?

    var body: some View {
        NavigationStack {
            List {
                if let error { ProblemView(message: error, compact: true) }
                if let l = listing {
                    if l.sessions.isEmpty {
                        Section {
                            Text("No sessions yet. Every terminal tab keeps one when “Keep terminal sessions” is on in Settings.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else {
                        Section {
                            ForEach(l.sessions) { s in
                                Button { open(s); dismiss() } label: { row(s) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("session.\(s.shortName)")
                                    .swipeActions {
                                        Button("End", role: .destructive) { ending = s }
                                    }
                            }
                        } footer: {
                            Text("Tap a session to open it in a new tab. Sessions keep running on the server when you leave.")
                        }
                    }
                    if !l.hasTmux { installSection }
                } else if error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { newName = ""; naming = true } label: { Image(systemName: "plus") }
                        .disabled(listing?.hasTmux != true)
                        .accessibilityLabel("New session")
                        .accessibilityIdentifier("session.new")
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sudoPassword(root, server: server)
            .alert("New session", isPresented: $naming) {
                TextField("Name", text: $newName).accessibilityIdentifier("session.name")
                Button("Start") { Task { await create() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A tmux session that keeps running on the server.")
            }
            .confirmationDialog(ending.map { String(localized: "End “\($0.shortName)”?") } ?? "", isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }), titleVisibility: .visible) {
                Button("End session", role: .destructive) { if let s = ending { Task { await end(s) } } }
            } message: {
                Text("Programs running in it stop.")
            }
        }
    }

    private func row(_ s: TerminalSessions.Session) -> some View {
        HStack(spacing: 10) {
            Image(systemName: s.kind == .tmux ? "rectangle.split.2x1" : "rectangle.on.rectangle")
                .foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.shortName).font(Theme.mono)
                Text(meta(s)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if s.attached {
                Circle().fill(.green).frame(width: 8, height: 8).accessibilityLabel("In use")
            }
        }
        .contentShape(Rectangle())
    }

    private func meta(_ s: TerminalSessions.Session) -> String {
        var parts = [s.kind == .tmux ? "tmux" : "screen"]
        if let w = s.windows { parts.append(w == 1 ? String(localized: "1 window") : String(localized: "\(w) windows")) }
        if let t = s.lastActivity { parts.append(t.formatted(.relative(presentation: .named))) }
        if openTabs.values.contains(s.name) || openTabs.values.contains(s.shortName) { parts.append(String(localized: "open in a tab")) }
        return parts.joined(separator: " · ")
    }

    private var installSection: some View {
        Section {
            Button { Task { await install() } } label: {
                HStack {
                    Text("Install tmux").font(.headline)
                    Spacer()
                    if installStep != nil { ProgressView() }
                }
            }
            .disabled(installStep != nil)
            .accessibilityIdentifier("session.installTmux")
            if let installStep {
                Label(installStep, systemImage: "hammer").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("tmux isn't installed")
        } footer: {
            Text(canSudo == false
                 ? "Without root, Deckhand builds tmux from its official sources into ~/.local (checked against fixed checksums). That takes a few minutes and needs a C compiler on the server."
                 : "Installs tmux from your distribution with sudo. Without root, Deckhand builds it into ~/.local instead.")
        }
    }

    // MARK: - Actions

    private func load() async {
        #if DEBUG
        // DECKHAND_SEED_SESSIONS="T,name,windows,attached,epoch|S,pid.name,Detached|HAS_TMUX": a listing without a server.
        if let seed = ProcessInfo.processInfo.environment["DECKHAND_SEED_SESSIONS"] {
            listing = TerminalSessions.parse(seed.replacingOccurrences(of: "|", with: "\n").replacingOccurrences(of: ",", with: "\t"))
            return
        }
        #endif
        do {
            let conn = try await connections.connection(for: server)
            listing = TerminalSessions.parse(try await conn.run(TerminalSessions.listCommand, timeout: .seconds(20)).stdout)
            error = nil
            if listing?.hasTmux == false, canSudo == nil {
                canSudo = ((try? await RootAccess.shared.access(for: server, connection: conn)) ?? .unavailable) != .unavailable
            }
        } catch { self.error = error.localizedDescription }
    }

    private func create() async {
        do {
            let conn = try await connections.connection(for: server)
            let name = TerminalSessions.clean(newName)
            let r = try await conn.run(TerminalSessions.newCommand(name: name) + " 2>&1", timeout: .seconds(20))
            if r.exitCode != 0 { error = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines); return }
            open(TerminalSessions.Session(kind: .tmux, name: name))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func end(_ s: TerminalSessions.Session) async {
        ending = nil
        do {
            let conn = try await connections.connection(for: server)
            _ = try await conn.run(TerminalSessions.killCommand(s), timeout: .seconds(20))
        } catch { self.error = error.localizedDescription }
        await load()
    }

    private func install() async {
        error = nil
        if canSudo == true {
            installStep = String(localized: "Installing with the package manager…")
            let ok = await root.run(TmuxInstall.packageScript, on: server)
            installStep = nil
            if ok { await load(); if listing?.hasTmux == true { return } }
        }
        await build()
    }

    /// Without root: builds tmux into ~/.local, showing each step.
    private func build() async {
        installStep = String(localized: "Starting…")
        var ok = false, noCompiler = false, last = ""
        do {
            let conn = try await connections.connection(for: server)
            let channel = try await conn.openChannel(TmuxInstall.buildScript + " 2>&1; echo \"@@end $?\"")
            defer { channel.close() }
            for try await line in channel.lines {
                if line.hasPrefix("@@step ") { installStep = String(localized: "Step: \(String(line.dropFirst(7)))…") }
                else if line == "@@nocc" { noCompiler = true }
                else if line == "@@ok" { ok = true }
                else if line.hasPrefix("@@badsum") { last = String(localized: "A download didn't match its checksum, so nothing was installed.") }
                else if line.hasPrefix("@@end") { break }
                else if !line.hasPrefix("@@"), !line.isEmpty { last = line }
            }
        } catch { self.error = error.localizedDescription }
        installStep = nil
        if noCompiler {
            error = String(localized: "The server has no C compiler or make, and no sudo to install tmux. Ask its admin to install tmux; GNU screen works too, if it's there.")
        } else if !ok, error == nil {
            error = last.isEmpty ? String(localized: "tmux couldn't be built.") : last
        }
        await load()
    }
}
