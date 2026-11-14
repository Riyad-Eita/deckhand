import DeckhandCore
import SwiftData
import SwiftUI

struct ServerView: View {
    let server: Server

    enum Tab: String, CaseIterable, Identifiable {
        case agent = "Agent"
        case server = "Server"
        case terminal = "Terminal"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .agent
    @State private var showingTools = false
    /// Engine + prompt for a task the agent tab should open right away.
    @State private var startTask: StartTask?
    /// A command for the terminal to run once it is connected (e.g. a CLI login).
    @State private var terminalCommand: String?
    @Environment(Connections.self) private var connections

    init(server: Server) {
        self.server = server
        #if DEBUG
        if DebugSeed.pendingRun?.engine == "server" { _tab = State(initialValue: .server) }
        if let run = DebugSeed.pendingRun, run.engine == "terminal" {
            _tab = State(initialValue: .terminal)
            if !run.prompt.isEmpty { _terminalCommand = State(initialValue: run.prompt) }
        }
        #endif
    }

    var body: some View {
        Group {
            switch tab {
            case .agent: ThreadListView(server: server, startTask: $startTask)
            case .server:
                ServerDashboardView(
                    server: server,
                    runInTerminal: { command in
                        terminalCommand = command
                        tab = .terminal
                    })
            case .terminal: TerminalScreen(server: server, pendingCommand: $terminalCommand)
            }
        }
        .navigationTitle(server.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingTools = true } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "wrench.and.screwdriver")
                        StatusDot(state: connections.state(for: server)).offset(x: 4, y: -3)
                    }
                }
                .accessibilityLabel("Server Tools")
            }
        }
        .onChange(of: showingTools) { _, showing in
            if showing {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .onChange(of: AppRouter.shared.pendingThread, initial: true) { _, id in
            if let id, server.threads?.contains(where: { $0.id == id }) == true { tab = .agent }
        }
        .sheet(isPresented: $showingTools) {
            ServerToolsView(server: server) { command in
                terminalCommand = command
                tab = .terminal
            }
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.environment["DECKHAND_SEED_TOOLS"] == "1" {
                try? await Task.sleep(for: .seconds(3))
                showingTools = true
            }
        }
        #endif
    }
}

struct StartTask: Equatable {
    let engine: Engine
    let prompt: String
}

struct ThreadListView: View {
    let server: Server
    @Binding var startTask: StartTask?
    @Environment(\.modelContext) private var context
    @State private var openThread: ChatThread?
    @State private var pickingFolderFor: Engine?
    @State private var signingIn: ServerCLI?
    @State private var showingSettings = false

    private func isReady(_ engine: Engine) -> Bool {
        if let cli = engine.serverCLI { return AgentStatus.shared.isSignedIn(cli, on: server) != false }
        return AppSettings.shared.isConfigured
    }

    @State private var taskSearch = ""
    @State private var sharing: URL?

    /// Pinned first, then newest; filtered by the search (titles and content).
    private var threads: [ChatThread] {
        let all = (server.threads ?? []).sorted { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
        guard !taskSearch.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.filter { TaskExport.match(taskSearch, title: $0.title, messages: $0.messages).matches }
    }

    private func pinButton(_ thread: ChatThread) -> some View {
        Button { thread.pinned.toggle() } label: {
            Label(thread.pinned ? String(localized: "Unpin") : String(localized: "Pin"), systemImage: thread.pinned ? "pin.slash" : "pin")
        }
    }

    private func snippet(_ thread: ChatThread) -> String? {
        taskSearch.isEmpty ? nil : TaskExport.match(taskSearch, title: thread.title, messages: thread.messages).snippet
    }

    var body: some View {
        List {
            Section {
                ForEach([Engine.claudeCode, .codex, .ownKey]) { engine in
                    Button {
                        // Not ready yet: sign in (or add a key) first instead of starting a task that fails.
                        if let cli = engine.serverCLI, AgentStatus.shared.isSignedIn(cli, on: server) == false {
                            signingIn = cli
                        } else if engine == .ownKey && !AppSettings.shared.isConfigured {
                            showingSettings = true
                        } else {
                            pickingFolderFor = engine
                        }
                    } label: { EngineRow(engine: engine, ready: isReady(engine)) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("engine.\(engine.rawValue)")
                }
            } header: {
                Text("Start a task with")
            }
            Section {
                NavigationLink { ServerMemoryView(server: server) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "note.text").foregroundStyle(Theme.accent).accessibilityHidden(true)
                        Text("Server notes").fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("agent.memory")
            } footer: {
                Text("What the agents remember about this server.")
            }
            if (server.threads?.count ?? 0) > 3 {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search tasks", text: $taskSearch)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("tasks.search")
                        if !taskSearch.isEmpty {
                            Button { taskSearch = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).accessibilityLabel("Clear search")
                        }
                    }
                }
            }
            if !threads.isEmpty {
                Section(taskSearch.isEmpty ? String(localized: "Recent") : String(localized: "\(threads.count) found")) {
                    ForEach(threads) { thread in
                        Button { openThread = thread } label: { TaskRow(thread: thread, snippet: snippet(thread)) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("task.\(thread.title)")
                        .swipeActions(edge: .leading) {
                            pinButton(thread)
                            .tint(.orange)
                        }
                        .contextMenu {
                            pinButton(thread)
                            Button { sharing = TaskShare.file(for: thread, server: server) } label: {
                                Label("Share as Markdown", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { context.delete(threads[i]) }
                    }
                }
            }
        }
        .navigationDestination(item: $openThread) { AgentChatView(thread: $0, server: server) }
        .sheet(item: Binding(get: { sharing.map { SharedFile(url: $0) } }, set: { sharing = $0?.url })) { f in
            ShareSheet(items: [f.url]).presentationDetents([.medium, .large])
        }
        .task { await AgentStatus.shared.refresh(server) }
        .sheet(item: $signingIn) { cli in CLILoginView(server: server, cli: cli) }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .onChange(of: AppRouter.shared.pendingThread, initial: true) { _, id in
            guard let id, let thread = threads.first(where: { $0.id == id }) else { return }
            AppRouter.shared.pendingThread = nil
            openThread = thread
        }
        .task(id: startTask) {
            guard let start = startTask else { return }
            startTask = nil
            let thread = ChatThread(server: server, workingDirectory: server.recentDirectories.first ?? server.workingDirectory, engine: start.engine)
            context.insert(thread)
            PendingPrompt.set(start.prompt, for: thread.id)
            openThread = thread
        }
        .sheet(item: $pickingFolderFor) { engine in
            FolderPicker(server: server, engine: engine) { folder in
                let thread = ChatThread(server: server, workingDirectory: folder, engine: engine)
                context.insert(thread)
                openThread = thread
            }
        }
        #if DEBUG
        .task {
            if let e = ProcessInfo.processInfo.environment["DECKHAND_SEED_PICK"], let engine = Engine(rawValue: e) {
                pickingFolderFor = engine
            }
        }
        .task {
            // "markdown|": a finished chat with a reply that uses every Markdown block (UI tests, screenshots).
            let seed = DebugSeed.pendingRun?.engine
            guard seed == "markdown" || seed == "secrets" || seed == "fix" || seed == "checkoffer" || seed == "compacted" || seed == "checkpoint" || seed == "plan" else { return }
            DebugSeed.pendingRun = nil
            let thread = ChatThread(server: server, workingDirectory: server.workingDirectory, engine: .codex)
            if seed == "plan" {
                thread.title = "Move the shop to port 8081"
                thread.planFirst = true
                thread.messages = DebugSeed.planChat
            }
            if seed == "checkpoint" {
                // A folder snapshotted at the start of the task, then changed the way an agent would.
                thread.title = "Tidy the notes"
                thread.workingDirectory = "~/dh-checkpoint-test"
                thread.messages = [.user("Tidy the notes."), Message(role: .assistant, blocks: [.text("Done: edited a.txt, added new.txt, removed old.txt.")])]
                if let conn = try? await Connections.shared.connection(for: server) {
                    _ = try? await conn.run("rm -rf ~/dh-checkpoint-test && mkdir -p ~/dh-checkpoint-test && cd ~/dh-checkpoint-test && printf 'one\\ntwo\\n' > a.txt && echo keep > old.txt", timeout: .seconds(20))
                    _ = try? await conn.run(Checkpoints.removeCommand(task: thread.id.uuidString), timeout: .seconds(20))
                    _ = try? await conn.run(Checkpoints.createCommand(task: thread.id.uuidString, folder: thread.workingDirectory), timeout: .seconds(30))
                    _ = try? await conn.run("cd ~/dh-checkpoint-test && printf 'one\\nTWO\\n' > a.txt && echo hi > new.txt && rm old.txt", timeout: .seconds(20))
                }
            }
            if seed == "compacted" {
                thread.title = "Upgrade the shop"
                thread.engineRaw = Engine.ownKey.rawValue
                thread.messages = DebugSeed.compactedChat
                thread.historyStart = 2
                thread.historySummary = "- Goal: upgrade the shop to Node 22\n- Installed Node 22, rebuilt the app\n- Open: restart the service"
            } else if seed == "checkoffer" {
                thread.title = "Why is Shop down?"
                thread.messages = DebugSeed.checkOfferChat
                IncidentLinks.set("seeded", for: thread.id)
            } else if seed == "fix" {
                thread.title = "Why is Shop down?"
                thread.messages = DebugSeed.fixChat
            } else if seed == "secrets" {
                thread.title = "Why can't the app reach the database?"
                thread.messages = DebugSeed.secretsChat
            } else if seed == "markdown" {
                thread.title = "Why does the API return 404?"
                thread.messages = [.user("Why does the weather API return 404 for some cities?"), DebugSeed.markdownReply]
            }
            context.insert(thread)
            openThread = thread
        }
        .task {
            guard let run = DebugSeed.pendingRun, let engine = Engine(rawValue: run.engine) else { return }
            DebugSeed.pendingRun = nil
            let thread = ChatThread(server: server, workingDirectory: server.workingDirectory, engine: engine)
            context.insert(thread)
            DebugSeed.pendingPrompt = run.prompt
            openThread = thread
        }
        #endif
    }
}

/// One engine as a tappable tile: logo, name, what it uses.
struct EngineTile: View {
    let engine: Engine
    /// false: needs a sign-in (CLI) or a key (own model) first.
    var ready = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrandIcon(brand: engine.brand, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.shortTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                if ready {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(engine == .ownKey ? String(localized: "Add a key") : String(localized: "Sign in"))
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline))
        .contentShape(RoundedRectangle(cornerRadius: Theme.corner))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ready ? Text("New task with \(engine.title)")
                            : engine == .ownKey ? Text("Add a key for \(engine.title)") : Text("Sign in to \(engine.title)"))
    }

    private var subtitle: String {
        switch engine {
        case .ownKey: AppSettings.shared.providerKind.displayName.components(separatedBy: " (").first ?? ""
        case .codex: String(localized: "ChatGPT plan")
        case .claudeCode: String(localized: "Claude plan")
        }
    }
}

/// One way to run a task, as a full-width row: works on every screen size.
struct EngineRow: View {
    let engine: Engine
    var ready = true

    var body: some View {
        HStack(spacing: 14) {
            BrandIcon(brand: engine.brand, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.shortTitle).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if ready {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            } else {
                Text(engine == .ownKey ? String(localized: "Add a key") : String(localized: "Sign in"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ready ? Text("New task with \(engine.title)")
                            : engine == .ownKey ? Text("Add a key for \(engine.title)") : Text("Sign in to \(engine.title)"))
    }

    private var detail: String {
        switch engine {
        case .claudeCode: String(localized: "Runs on this server with your Claude plan")
        case .codex: String(localized: "Runs on this server with your ChatGPT plan")
        case .ownKey:
            AppSettings.shared.isConfigured
                ? String(localized: "\(AppSettings.shared.providerKind.displayName.components(separatedBy: " (").first ?? "") · runs in the app")
                : String(localized: "Your own API key · runs in the app")
        }
    }
}

/// A task as a Markdown file in the temporary folder, for the share sheet.
enum TaskShare {
    @MainActor
    static func file(for thread: ChatThread, server: Server?) -> URL? {
        let md = TaskExport.markdown(title: thread.title, server: server?.displayName, folder: thread.workingDirectory,
                                     date: thread.updatedAt, messages: thread.messages)
        let dir = FileManager.default.temporaryDirectory.appending(path: "exports/\(thread.id.uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: TaskExport.fileName(for: thread.title))
        do { try Data(md.utf8).write(to: url, options: .completeFileProtection); return url } catch { return nil }
    }
}

struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// A task in the server's list: engine, title (pinned mark), search snippet, folder and age, running badge.
private struct TaskRow: View {
    let thread: ChatThread
    let snippet: String?

    var body: some View {
        HStack(spacing: 12) {
            BrandIcon(brand: thread.engine.brand, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if thread.pinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange).accessibilityLabel("Pinned")
                    }
                    Text(thread.title).font(.body).foregroundStyle(.primary).lineLimit(1)
                }
                if let snippet {
                    Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .accessibilityIdentifier("tasks.snippet")
                }
                HStack(spacing: 4) {
                    Text(thread.engine.shortTitle)
                    Text("·")
                    Text(thread.workingDirectory).lineLimit(1).truncationMode(.head)
                    Text("·")
                    Text(thread.updatedAt, format: .relative(presentation: .named))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if thread.cliRunActive {
                Text("Running").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.13), in: Capsule())
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
