import DeckhandCore
import LocalAuthentication
import SwiftData
import SwiftUI
import UIKit

/// The agent looks into failures by itself: switch it on per server, pick the agent, the triggers and a daily limit,
/// and see each investigation with its cause and fix — Apply (Face ID) or Dismiss, also from the lock screen.
struct InvestigationsView: View {
    let server: Server
    /// Scrolls to and highlights this investigation (from a push).
    var focus: String?
    private var connections: Connections { .shared }
    private var settings: AppSettings { .shared }
    @Environment(\.modelContext) private var context
    @State private var status: AutoInvestigate.Status?
    @State private var error: String?
    @State private var busy: String?
    @State private var editing = false
    @State private var openTask: ChatThread?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let error { ProblemView(message: error, compact: true) }
                if let status {
                    Section {
                        Toggle(isOn: Binding(get: { status.installed }, set: { on in Task { on ? await install(status.config ?? defaultConfig) : await uninstall() } })) {
                            Label("Look into failures by itself", systemImage: "stethoscope")
                        }
                        .disabled(busy != nil || !status.python)
                        .accessibilityIdentifier("investigate.toggle")
                        if status.installed, let c = status.config {
                            Button { editing = true } label: {
                                LabeledContent("Agent", value: c.cli.displayName)
                            }
                            .foregroundStyle(.primary)
                            LabeledContent("Watches", value: watches(c))
                            LabeledContent("Today", value: String(localized: "\(status.startedToday()) of \(c.maxPerDay) runs"))
                            Button("Check Now") { Task { await checkNow() } }.disabled(busy != nil)
                                .accessibilityIdentifier("investigate.check")
                        }
                    } footer: {
                        if !status.python {
                            Text("Needs python3 on the server.")
                        } else if settings.ntfyTopicURL.isEmpty {
                            Text("Set up notifications in Settings to get the cause and the fix as a push, with Apply and Dismiss on the lock screen.")
                        } else {
                            Text("A failing uptime check, a crashed service or a full disk starts a read-only run on the server — your phone can be off. Nothing changes until you approve the fix.")
                        }
                    }
                    if status.investigations.isEmpty {
                        if status.installed {
                            ContentUnavailableView("All quiet", systemImage: "checkmark.seal", description: Text("When something fails, the investigation shows up here."))
                        }
                    } else {
                        Section("Investigations") {
                            ForEach(status.investigations) { inv in
                                InvestigationRow(inv: inv, highlighted: inv.id == focus, busy: busy == inv.id,
                                                 apply: { Task { await apply(inv) } }, dismiss: { Task { await dismiss(inv) } },
                                                 open: { run in openRun(run, title: inv) })
                                    .id(inv.id)
                            }
                        }
                    }
                } else if error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                }
            }
            .onChange(of: status?.investigations.count) { if let focus { withAnimation { proxy.scrollTo(focus, anchor: .top) } } }
        }
        .navigationTitle("Auto-investigate")
        .task { await load() }
        .refreshable { await load() }
        .appSheet(isPresented: $editing) {
            InvestigateSettingsSheet(config: status?.config ?? defaultConfig) { c in Task { await install(c) } }
        }
        .navigationDestination(item: $openTask) { AgentChatView(thread: $0, server: server) }
    }

    private var defaultConfig: AutoInvestigate.Config {
        let cli = AgentStatus.shared.clis(for: server).last ?? .claudeCode
        return AutoInvestigate.Config(cli: cli, options: settings.cliOptions(for: cli), topic: settings.ntfyTopicURL,
                                      server: server.id.uuidString, name: server.displayName)
    }

    private func watches(_ c: AutoInvestigate.Config) -> String {
        var parts: [String] = []
        if c.uptime { parts.append(String(localized: "uptime checks")) }
        if c.services { parts.append(String(localized: "services")) }
        if c.disk { parts.append(String(localized: "disks ≥ \(c.diskPercent) %")) }
        if !c.repos.isEmpty { parts.append(String(localized: "CI of \(c.repos.map(\.repo).joined(separator: ", "))")) }
        return parts.isEmpty ? String(localized: "nothing") : parts.joined(separator: ", ")
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            status = AutoInvestigate.parse(try await conn.run(AutoInvestigate.statusCommand, timeout: .seconds(20)).stdout)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func run(_ command: String, key: String, timeout: Duration = .seconds(30)) async -> String? {
        busy = key
        defer { busy = nil }
        do {
            let conn = try await connections.connection(for: server)
            return try await conn.run(command, timeout: timeout).stdout
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func install(_ c: AutoInvestigate.Config) async {
        var c = c
        c.topic = settings.ntfyTopicURL; c.server = server.id.uuidString; c.name = server.displayName
        c.maxBudgetUSD = HouseRulesStore.rules(for: server)?.maxSpendUSD
        let out = await run(AutoInvestigate.installCommand(c), key: "install") ?? ""
        if out.contains("@@nopython") { error = String(localized: "This server has no python3, which the checker needs.") }
        else if out.contains("@@nocron") { error = String(localized: "This server has no cron, so nothing can run on a schedule.") }
        await load()
    }

    private func uninstall() async {
        _ = await run(AutoInvestigate.uninstallCommand, key: "install")
        await load()
    }

    private func checkNow() async {
        _ = await run(AutoInvestigate.checkNowCommand, key: "check", timeout: .seconds(180))
        await load()
    }

    private func apply(_ inv: AutoInvestigate.Investigation) async {
        var skip = false
        #if DEBUG
        skip = ProcessInfo.processInfo.environment["DECKHAND_SEED_SKIPAUTH"] == "1"
        #endif
        if !skip {
            let ctx = LAContext()
            guard (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Apply a fix on the server"))) == true else { return }
        }
        let out = await run(AutoInvestigate.applyCommand(id: inv.id, device: UIDevice.current.name), key: inv.id) ?? ""
        if let line = out.split(separator: "\n").first(where: { $0.hasPrefix("@@blocked ") }) {
            error = String(localized: "A house rule stopped the fix: \(String(line.dropFirst(10)))")
        }
        await load()
    }

    private func dismiss(_ inv: AutoInvestigate.Investigation) async {
        _ = await run(AutoInvestigate.dismissCommand(id: inv.id, device: UIDevice.current.name), key: inv.id)
        await load()
    }

    private func openRun(_ run: String, title inv: AutoInvestigate.Investigation) {
        let engine: Engine = status?.config?.cli == .codex ? .codex : .claudeCode
        openTask = ServerRuns.thread(for: run, title: InvestigationRow.title(inv), engine: engine, directory: "~", server: server, context: context)
    }
}

/// One investigation: what failed, the cause, the fix and what happened to it.
struct InvestigationRow: View {
    let inv: AutoInvestigate.Investigation
    var highlighted = false
    var busy = false
    let apply: () -> Void
    let dismiss: () -> Void
    let open: (String) -> Void

    static func title(_ inv: AutoInvestigate.Investigation) -> String {
        switch inv.kind {
        case .uptime: String(localized: "Uptime check “\(inv.name ?? inv.arg)” failed")
        case .service: String(localized: "\(inv.arg) failed")
        case .disk: String(localized: "Disk \(inv.arg) is \(inv.percent ?? 0) % full")
        case .ci: String(localized: "CI failed: \(inv.name ?? "CI") on \(inv.branch ?? "?")")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.title(inv)).font(.headline)
                Spacer()
                pill
            }
            HStack(spacing: 4) {
                if inv.kind == .ci { Text(inv.arg).font(.caption.monospaced()) ; Text("·") }
                Text(inv.started, format: .relative(presentation: .named))
            }
            .font(.caption).foregroundStyle(.secondary)
            if let cause = inv.cause { Text(cause).font(.subheadline) }
            if let fix = inv.fix {
                Text(fix).font(Theme.monoSmall).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)
                if inv.risky == true {
                    Label("Contains a command that can't easily be undone — only the app can approve it, with \(Device.biometry).", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if let note = inv.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            if let result = inv.result, !result.isEmpty {
                if let url = URL(string: result), result.hasPrefix("https://github.com/") {
                    Link(destination: url) { Label("Open the pull request", systemImage: "arrow.triangle.pull") }.font(.subheadline)
                } else {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                if inv.status == .proposed {
                    Button(action: apply) { HStack { if busy { ProgressView() }; Text(inv.kind == .ci ? "Open Pull Request" : "Apply Fix") } }
                        .buttonStyle(.borderedProminent).disabled(busy)
                        .accessibilityIdentifier("investigate.apply")
                    Button("Dismiss", action: dismiss).buttonStyle(.bordered).disabled(busy)
                        .accessibilityIdentifier("investigate.dismiss")
                }
                Spacer()
                if let link = inv.url.flatMap(URL.init(string:)), inv.kind == .ci {
                    Link(destination: link) { Label("Run", systemImage: "safari") }.font(.caption)
                }
                if let run = inv.applyRun ?? inv.run {
                    Button { open(run) } label: { Label("Task", systemImage: "list.bullet.rectangle") }.font(.caption).buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(highlighted ? Theme.accent.opacity(0.08) : nil)
        .accessibilityIdentifier("investigation.row")
    }

    @ViewBuilder private var pill: some View {
        let (text, color): (String, Color) = switch inv.status {
        case .running: (String(localized: "Looking…"), Theme.accent)
        case .proposed: (String(localized: "Fix ready"), .orange)
        case .nofix: (String(localized: "No fix needed"), .secondary)
        case .failed: (String(localized: "Didn't finish"), .red)
        case .limited: (String(localized: "Daily limit"), .secondary)
        case .applying: (String(localized: "Applying…"), Theme.accent)
        case .fixed: (String(localized: "Fixed"), .green)
        case .stillfailing: (String(localized: "Still failing"), .red)
        case .blocked: (String(localized: "Blocked by a house rule"), .orange)
        case .dismissed: (String(localized: "Dismissed"), .secondary)
        case .resolved: (String(localized: "Went away"), .green)
        }
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
    }
}

/// Agent, triggers and limits.
private struct InvestigateSettingsSheet: View {
    @State var config: AutoInvestigate.Config
    let save: (AutoInvestigate.Config) -> Void
    @State private var newRepo = ""
    @State private var newDir = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("Agent", selection: $config.cli) { ForEach(ServerCLI.allCases.reversed()) { Text($0.displayName).tag($0) } }
                Section("Look into") {
                    Toggle("Failing uptime checks", isOn: $config.uptime)
                    Toggle("Crashed services", isOn: $config.services)
                    Toggle("Full disks", isOn: $config.disk)
                    if config.disk { Stepper("From \(config.diskPercent) % full", value: $config.diskPercent, in: 50...99, step: 5) }
                }
                Section {
                    ForEach(config.ciRepos ?? []) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.repo).font(Theme.mono)
                            Text(r.dir).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { config.ciRepos?.remove(atOffsets: $0) }
                    TextField("owner/repository", text: $newRepo).textInputAutocapitalization(.never).autocorrectionDisabled().font(Theme.mono)
                        .accessibilityIdentifier("investigate.repo")
                    TextField("Checkout on the server, e.g. ~/shop", text: $newDir).textInputAutocapitalization(.never).autocorrectionDisabled().font(Theme.mono)
                    Button("Add Repository") {
                        let r = AutoInvestigate.Config.CIRepo(repo: newRepo.trimmingCharacters(in: .whitespaces), dir: newDir.isEmpty ? "~" : newDir.trimmingCharacters(in: .whitespaces))
                        if r.isValid { config.ciRepos = (config.ciRepos ?? []).filter { $0.repo != r.repo } + [r]; newRepo = ""; newDir = "" }
                    }
                    .disabled(!AutoInvestigate.Config.CIRepo(repo: newRepo, dir: newDir.isEmpty ? "~" : newDir).isValid)
                } header: {
                    Text("Failed GitHub Actions runs")
                } footer: {
                    Text("Uses the GitHub CLI signed in on the server (Connections → GitHub). It looks every few minutes — no webhook, nothing public. With your approval the agent opens a pull request on a new branch.")
                }
                Section {
                    Stepper("At most \(config.maxPerDay) a day", value: $config.maxPerDay, in: 1...20)
                } footer: {
                    Text("Each run uses your Claude or ChatGPT plan. Runs are read-only; a fix runs only after you approve it, within the house rules.")
                }
            }
            .navigationTitle("Auto-investigate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(config); dismiss() } }
            }
        }
    }
}

/// Runs the server started by itself (scheduled tasks, investigations) opened as tasks: the run is read from the
/// start, so its messages and action log show up like any other task.
enum ServerRuns {
    @MainActor static func thread(for runID: String, title: String, engine: Engine, directory: String, server: Server, context: ModelContext) -> ChatThread {
        if let existing = (server.threads ?? []).first(where: { $0.cliRunID == runID }) { return existing }
        let thread = ChatThread(server: server, workingDirectory: directory, engine: engine)
        thread.title = title
        thread.cliRunID = runID
        thread.cliRunLine = 1
        // Only read: ChatModel reattaches (start: false) and never starts the run again.
        thread.cliRunActive = true
        context.insert(thread)
        try? context.save()
        return thread
    }
}
