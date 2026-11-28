import DeckhandCore
import DeckhandSSH
import Foundation
import Observation
import SwiftData

/// Drives one agent conversation: streams model output, shows tool calls, asks for approvals.
@MainActor
@Observable
final class ChatModel {
    struct PendingApproval: Identifiable {
        let id = UUID()
        let call: ToolCall
        let danger: String?
        /// The house rule this call breaks (allowing it overrides the rule once).
        var rule: String? = nil
        let respond: (ApprovalDecision) -> Void
    }

    enum ToolStatus: Equatable {
        case streaming, waiting, running, done(ToolResult)
    }

    let thread: ChatThread
    let server: Server
    private(set) var messages: [Message]
    /// Text and thinking of the assistant message being streamed right now.
    private(set) var liveText = ""
    private(set) var liveThinking = ""
    private(set) var liveTools: [(id: String, name: String, input: String)] = []
    private(set) var toolStatus: [String: ToolStatus] = [:]
    private(set) var isRunning = false {
        didSet {
            // Keep a running chat alive across views, so reopening it shows the same live run.
            if isRunning { Self.live[thread.id] = self } else if Self.live[thread.id] === self { Self.live[thread.id] = nil }
        }
    }
    private static var live: [UUID: ChatModel] = [:]

    /// The chat model for a thread: the one still running if there is one, otherwise a fresh one.
    static func model(for thread: ChatThread, server: Server) -> ChatModel {
        live[thread.id] ?? ChatModel(thread: thread, server: server)
    }
    private(set) var runStartedAt = Date()
    var error: String?
    /// Non-fatal information for the current run (e.g. a connection that could not be opened).
    private(set) var notice: String?
    /// "Start after the reset": the next server run waits on the server until then.
    var startAfter: Date?
    private(set) var usage = Usage()
    var pendingApproval: PendingApproval?
    /// The plan in the last reply that is waiting to be run, adjusted or dropped, and the steps the user unticked.
    var planHandled: UUID?
    var planSkipped: Set<Int> = []
    var planOffer: (message: UUID, steps: [String])? {
        guard !isRunning, let last = messages.last, last.role == .assistant, last.id != planHandled,
              let steps = PlanMode.steps(in: last.text) else { return nil }
        return (last.id, steps)
    }
    /// Sudo for a server run with full access: asked once per app session, kept in memory only.
    var sudoPrompt = false
    var sudoPassword = ""
    private(set) var sudoWrong = false
    private var sudoReply: CheckedContinuation<Bool, Never>?
    private var task: Task<Void, Never>?
    private var waitingForLimit = false
    private var waitingLine = 0

    /// The views the agent drew with `show_ui` (A2UI), rebuilt from the history.
    let a2ui = A2UIHost()

    init(thread: ChatThread, server: Server) {
        self.thread = thread
        self.server = server
        self.messages = thread.messages
        a2ui.replay(messages)
        // A tap on a button the agent drew is the user's next message (with the A2UI action for the agent).
        a2ui.onAction = { [weak self] action in
            guard let self, !self.isRunning else { return }
            self.send(A2UI.message(for: action))
        }
    }

    /// A server run that was going when the app closed or the connection dropped: pick it up again.
    func resumeIfNeeded() {
        guard !isRunning, thread.cliRunActive, let id = thread.cliRunID, let cli = thread.serverRunCLI else { return }
        isRunning = true
        LiveTasks.shared.start(thread, server: server)
        notice = String(localized: "Reattaching to the run on the server…")
        task = Task { await follow(cli, run: DetachedRun(id: id), prompt: "", access: AppSettings.shared.cliAccess, start: false) }
    }

    /// Reads a detached server run until it ends; reconnects and continues from the last line if the connection drops.
    /// Asks the checker on the server about one own-key tool call.
    nonisolated static func ruleChecker(shell: any RemoteShell, workingDirectory: String) -> @Sendable (ToolCall) async -> HouseRules.Block? {
        { call in
            guard let cmd = HouseRules.checkCommand(call, workingDirectory: workingDirectory) else { return nil }
            return HouseRules.parseVerdict((try? await shell.run(cmd, timeout: .seconds(15)).stdout) ?? "")
        }
    }

    /// Model and effort from Settings, the spending cap from the server's house rules.
    private func cliOptions(_ cli: ServerCLI) -> CLIOptions {
        var o = AppSettings.shared.cliOptions(for: cli, thread: thread)
        o.maxBudgetUSD = HouseRulesStore.rules(for: server)?.maxSpendUSD
        o.instructions = A2UI.sessionGuide   // the session may answer with views the chat draws
        return o
    }

    private func follow(_ cli: ServerCLI, run: DetachedRun, prompt: String, access: CLIAccess, start: Bool, sudo: Bool = false, apiKey: Bool = false) async {
        // Claude Code with "Edit files" asks the phone before other steps (commands): answer them while it runs.
        var options = cliOptions(cli)
        // An own-key task on the server uses the model chosen for the key, not the CLI's default.
        if thread.engine == .ownKey { options.model = AppSettings.shared.providerConfig.model; options.effort = nil }
        let asks = cli == .claudeCode && access == .edit
        if asks { options.askDirectory = PermissionPrompt.directory(for: run) }
        let watcher = asks ? Task { await watchPermissionRequests(PermissionPrompt.directory(for: run)) } : nil
        defer {
            watcher?.cancel()
            // A question still open when the run ends has nobody left to answer it.
            if pendingApproval?.call.id.hasPrefix("ask-") == true { pendingApproval?.respond(.deny(reason: nil)) }
        }
        var delay: Double = 2
        var reconnecting = !start
        var starting = start
        if starting { TaskNotifier.shared.requestPermission() }
        let topic = AppSettings.shared.ntfyTopicURL
        let notify = topic.isEmpty ? nil : DetachedRun.Notify(
            topicURL: topic, doneMessage: String(localized: "Done: \(thread.title)"),
            failedMessage: String(localized: "Didn't finish: \(thread.title)"), click: AppRouter.link(for: thread.id))
        while !Task.isCancelled {
            do {
                let shell = try await Connections.shared.connection(for: server)
                let events = ServerCLIRun.runDetached(
                    cli, shell: shell, prompt: prompt, workingDirectory: thread.workingDirectory,
                    sessionID: thread.cliSessionID, access: access, options: options,
                    run: run, fromLine: thread.cliRunLine, start: starting,
                    meta: DetachedRun.Meta(title: thread.title, engine: cli.displayName, directory: thread.workingDirectory),
                    notify: notify, startAt: starting ? startAfter : nil, sudo: sudo, apiKey: apiKey && starting)
                if starting { startAfter = nil }
                for try await event in events {
                    // Started: a dropped connection from here on only reattaches.
                    starting = false
                    if reconnecting { notice = nil; reconnecting = false; delay = 2 }
                    handle(event)
                }
                break
            } catch let e as CLIError where e.message != "Lost the connection to the run." {
                self.error = e.localizedDescription
                break
            } catch {
                if Task.isCancelled { break }
                // Connection trouble: the run keeps going on the server. Try again with growing pauses.
                notice = String(localized: "Connection lost — the run continues on the server. Reconnecting…")
                reconnecting = true
                await Connections.shared.disconnect(server)
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
        if !Task.isCancelled {
            thread.cliRunActive = false
            TaskNotifier.shared.taskFinished(thread, ok: error == nil)
            LiveTasks.shared.end(thread, ok: error == nil)
        } else {
            LiveTasks.shared.end(thread, ok: false, stopped: true)
        }
        clearLive()
        isRunning = false
        persist()
    }

    /// Polls a Claude Code run's permission requests and shows each in the approval bar; the answer goes back to
    /// the server, where the run waits for it (or refuses the step after a while without one).
    private func watchPermissionRequests(_ directory: String) async {
        var answered = Set<String>()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard pendingApproval == nil, let conn = try? await Connections.shared.connection(for: server),
                  let out = try? await conn.run(PermissionPrompt.pendingCommand(directory: directory), timeout: .seconds(10)).stdout,
                  let request = PermissionPrompt.parsePending(out).first(where: { !answered.contains($0.id) }) else { continue }
            let call = PermissionPrompt.call(for: request)
            TaskNotifier.shared.approvalNeeded(thread, command: call.input["command"]?.stringValue ?? call.name)
            LiveTasks.shared.update(thread, phase: .approval, step: LiveTasks.step(for: call), force: true)
            let decision: ApprovalDecision = await withCheckedContinuation { continuation in
                pendingApproval = PendingApproval(call: call, danger: DangerCheck.assess(call)) { [weak self] d in
                    self?.pendingApproval = nil
                    continuation.resume(returning: d)
                }
            }
            answered.insert(request.id)
            if Task.isCancelled { break }
            LiveTasks.shared.update(thread, phase: .running, step: String(localized: "Working…"), force: true)
            let allow: Bool, reason: String?
            switch decision {
            case .allow: allow = true; reason = nil
            case .deny(let r): allow = false; reason = r
            }
            if let cmd = PermissionPrompt.answerCommand(directory: directory, id: request.id, allow: allow, message: reason) {
                _ = try? await conn.run(cmd, timeout: .seconds(10))
            }
        }
    }

    /// Sets up sudo for `run` when this login needs a password for it. Asks for the password if the app
    /// doesn't have it yet; false means the run goes without sudo (no sudo, skipped, or it couldn't be set up).
    private func prepareSudo(_ run: DetachedRun, connection: SSHConnection) async -> Bool {
        guard let access = try? await RootAccess.shared.access(for: server, connection: connection), access == .password else { return false }
        sudoWrong = false
        while !Task.isCancelled {
            if RootAccess.shared.password(for: server) == nil {
                sudoPrompt = true
                guard await withCheckedContinuation({ sudoReply = $0 }) else { return false }
            }
            guard let password = RootAccess.shared.password(for: server) else { return false }
            switch try? await RunSudo.prepare(run, password: password, on: connection) {
            case .ok?: return true
            case .wrongPassword?:
                RootAccess.shared.setPassword(nil, for: server)
                sudoWrong = true
            default: return false
            }
        }
        return false
    }

    func submitSudoPassword() {
        RootAccess.shared.setPassword(sudoPassword, for: server)
        sudoPassword = ""
        sudoReply?.resume(returning: true)
        sudoReply = nil
    }

    func skipSudo() {
        sudoPassword = ""
        sudoReply?.resume(returning: false)
        sudoReply = nil
    }

    struct RunKeyError: LocalizedError {
        var errorDescription: String? { String(localized: "Your key couldn't be handed to the server run. Try again, or run the task in the app.") }
    }

    /// Moves this own-key task to the server (Claude Code with an Anthropic key, Codex with an OpenAI key) or back.
    func setRunsOnServer(_ on: Bool) {
        thread.ownKeyOnServerRaw = on ? RunKey.cli(for: AppSettings.shared.providerKind)?.rawValue : nil
        persist()
    }

    func result(for callID: String) -> ToolResult? {
        for message in messages {
            for case .toolResult(let r) in message.blocks where r.toolUseID == callID { return r }
        }
        return nil
    }

    /// `access` overrides the CLI access from Settings for this turn (read-only diagnosis, an approved fix).
    /// `plan`: nil follows the thread's "Plan first" switch; false runs normally (e.g. carrying out a plan).
    func send(_ text: String, access accessOverride: CLIAccess? = nil, plan: Bool? = nil, images: [Data] = []) {
        let planning = plan ?? thread.planFirst
        var asked = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if asked.isEmpty && !images.isEmpty { asked = String(localized: "What do you see here?") }
        let trimmed = planning && !asked.isEmpty ? PlanMode.wrap(asked) : asked
        guard !trimmed.isEmpty, !isRunning else { return }
        let settings = AppSettings.shared
        guard thread.engine != .ownKey || settings.isConfigured else {
            error = LLMError.missingAPIKey.localizedDescription
            return
        }
        if thread.engine == .ownKey,
           case .stop(let why) = Spend.check(task: spent.cost, day: settings.spentToday, limits: settings.spendLimits) {
            error = why
            return
        }
        error = nil
        notice = nil
        spendStop = nil
        runningModel = settings.providerConfig.model
        let user = Message(role: .user, blocks: images.map { .image(mediaType: "image/jpeg", data: $0) } + [.text(trimmed)])
        let history = Self.history(messages, start: thread.historyStart, summary: thread.historySummary)
        let historyStart = thread.historyStart
        messages.append(user)
        if history.isEmpty {
            thread.title = String(asked.prefix(60))
            // A short title from the on-device model, if this iPhone has one (free, private).
            let request = asked, thread = thread
            Task { if let t = await QuickAI.title(for: request) { thread.title = t } }
        }
        persist()
        isRunning = true
        runStartedAt = Date()
        LiveTasks.shared.start(thread, server: server)
        let config = settings.providerConfig
        // A plan turn only looks: reading runs, anything else waits for the user (own key) or is read-only (CLIs).
        let policy = planning && settings.approvalPolicy == .auto ? .autoRead : settings.approvalPolicy
        // An own-key task on the server keeps the key's approval rule: "ask" means Edit files, where Claude Code asks
        // the phone before commands; "auto" means full access.
        let ownKeyAccess: CLIAccess? = thread.engine == .ownKey && thread.serverRunCLI != nil
            ? (settings.approvalPolicy == .auto ? .full : .edit) : nil
        let access = planning ? .readOnly : accessOverride ?? ownKeyAccess ?? settings.cliAccess
        let hideSecrets = settings.hideSecrets
        task = Task {
            do {
                let shell = try await Connections.shared.connection(for: server)
                // Snapshot the folder before the agent touches it, so every change can be seen and undone.
                _ = try? await shell.run(Checkpoints.createCommand(task: thread.id.uuidString, folder: thread.workingDirectory), timeout: .seconds(60))
                if let cli = thread.serverRunCLI {
                    let run = DetachedRun()
                    // Full access includes sudo: the run gets the password through a helper that leaves with it.
                    let sudo = access == .full ? await prepareSudo(run, connection: shell) : false
                    // Own key on the server: the key goes over stdin into a file the run deletes before the CLI starts.
                    let keyed = thread.engine == .ownKey
                    if keyed, !(try await RunKey.prepare(run, key: settings.apiKey, on: shell)) {
                        throw RunKeyError()
                    }
                    thread.cliRunID = run.id
                    thread.cliRunLine = 1
                    thread.cliRunActive = true
                    await follow(cli, run: run, prompt: trimmed, access: access, start: true, sudo: sudo, apiKey: keyed)
                    return
                }
                let records = (try? thread.modelContext?.fetch(FetchDescriptor<ConnectionRecord>())) ?? []
                // The browser on this server (Server → Browser for the agent), when it is switched on there.
                let browser = planning ? [] : [BrowserAccess.connection(for: server)].compactMap { $0 }.map { ($0, String?.none) }
                let mcp = await MCPConnector.open(records.map { ($0.spec, $0.token) } + browser, server: shell)
                defer { Task { await mcp.close() } }
                if !mcp.failures.isEmpty {
                    notice = "Not available this time: " + mcp.failures.map { "\($0.name) (\($0.error))" }.joined(separator: ", ")
                }
                // House rules: the checker on the server sees every call; a broken rule always waits for the user.
                let rules = HouseRules.decode((try? await shell.run(HouseRules.readCommand, timeout: .seconds(10)).stdout) ?? "")
                HouseRulesStore.set(rules, for: server)
                let ruleCheck = rules == nil ? nil : Self.ruleChecker(shell: shell, workingDirectory: thread.workingDirectory)
                let agent = Agent(
                    provider: AppProviders.make(config),
                    shell: shell,
                    tools: (planning ? PlanMode.tools(ServerTools.all(workingDirectory: thread.workingDirectory))
                        : ServerTools.all(workingDirectory: thread.workingDirectory) + mcp.tools)
                        + [ShowUITool(validate: { [a2ui] messages in await a2ui.apply(messages) })],
                    policy: policy,
                    system: Agent.systemPrompt(
                        host: server.host, user: server.username, workingDirectory: thread.workingDirectory,
                        extra: ServerMemory.promptSection((try? await shell.run(ServerMemory.readCommand, timeout: .seconds(10)).stdout) ?? "")
                            + "\n" + Skills.promptSection(Skills.parseList((try? await shell.run(Skills.listCommand, timeout: .seconds(10)).stdout) ?? ""))),
                    redactSecrets: hideSecrets,
                    ruleCheck: ruleCheck,
                    approve: { [weak self] request in
                        await self?.requestApproval(request) ?? .deny(reason: nil)
                    })
                for try await event in agent.run(history: history, userMessage: user) {
                    if case .compacted(let summary, let dropped) = event {
                        thread.historySummary = summary
                        thread.historyStart = min(historyStart + dropped, messages.count)
                    }
                    handle(event)
                    // A spending limit was reached: no further model calls.
                    if let why = spendStop { self.error = why; notice = nil; break }
                }
            } catch {
                self.error = error.localizedDescription
            }
            LiveTasks.shared.end(thread, ok: error == nil, stopped: Task.isCancelled)
            clearLive()
            isRunning = false
            persist()
        }
    }

    func stop() {
        if thread.cliRunActive, let id = thread.cliRunID {
            thread.cliRunActive = false
            let server = self.server
            Task {
                if let conn = try? await Connections.shared.connection(for: server) {
                    _ = try? await conn.run(DetachedRun(id: id).stopCommand, timeout: .seconds(15))
                }
            }
        }
        task?.cancel()
        pendingApproval?.respond(.deny(reason: "Stopped by the user."))
    }

    private func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        toolStatus[request.call.id] = .waiting
        TaskNotifier.shared.approvalNeeded(thread, command: request.call.input["command"]?.stringValue ?? request.call.name)
        LiveTasks.shared.update(thread, phase: .approval, step: LiveTasks.step(for: request.call), force: true)
        return await withCheckedContinuation { continuation in
            pendingApproval = PendingApproval(call: request.call, danger: request.danger,
                                              rule: request.rule.map { HouseRulesStore.rules(for: server)?.title(for: $0) ?? $0.title }) { [weak self] decision in
                self?.pendingApproval = nil
                #if targetEnvironment(macCatalyst)
                if let self {
                    MenuBarBridge.shared.approvalDone(self.thread.id)
                    LiveTasks.shared.update(self.thread, phase: .running, step: String(localized: "Working…"), force: true)
                }
                #endif
                continuation.resume(returning: decision)
            }
            #if targetEnvironment(macCatalyst)
            // Allow / Deny right from the menu bar.
            MenuBarBridge.shared.waitForApproval(thread.id) { [weak self] allow in
                self?.pendingApproval?.respond(allow ? .allow : .deny(reason: "Denied from the menu bar."))
            }
            #endif
        }
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .textDelta(let t): liveText += t
        case .thinkingDelta(let t): liveThinking += t
        case .toolCallStarted(let id, let name):
            liveTools.append((id, name, ""))
            toolStatus[id] = .streaming
        case .toolInputDelta(let id, let fragment):
            if let i = liveTools.firstIndex(where: { $0.id == id }) { liveTools[i].input += fragment }
        case .message(let message):
            a2ui.take(message)   // views in a session's reply or an MCP tool's result
            messages.append(message)
            clearLive()
            persist()
        case .toolRunning(let call):
            toolStatus[call.id] = .running
            LiveTasks.shared.update(thread, phase: .running, step: LiveTasks.step(for: call))
        case .toolFinished(let call, let result): toolStatus[call.id] = .done(result)
        case .checkpoint(let line):
            thread.cliRunLine = line
            if waitingForLimit, line > waitingLine { waitingForLimit = false; notice = nil }
        case .waitingForLimit(let until):
            LiveTasks.shared.update(thread, phase: .waiting, step: "", waitingUntil: until, force: true)
            waitingForLimit = true
            waitingLine = thread.cliRunLine + 1
            let time = until.formatted(Calendar.current.isDateInToday(until) ? .dateTime.hour().minute() : .dateTime.weekday().hour().minute())
            notice = String(localized: "Usage limit reached. The task waits on the server and continues at \(time) by itself — you can close the app.")
        case .sessionStarted(let id):
            thread.cliSessionID = id
        case .compacted:
            persist()
        case .usage(let u):
            usage.inputTokens += u.inputTokens
            usage.outputTokens += u.outputTokens
            if thread.engine == .ownKey { recordOwnKeyUsage(u) }
        case .finished(let reason):
            switch reason {
            case .refusal: error = "The model declined this request."
            case .maxTokens: error = "The reply hit the output limit."
            default: break
            }
        }
    }

    /// The model of the running own-key task (set when it starts).
    private var runningModel: String?
    /// Set when a spending limit is reached: the task stops before its next model call.
    private var spendStop: String?

    /// Puts a reply's tokens on it (with the model) and on today's ledger, then checks the limits.
    private func recordOwnKeyUsage(_ u: Usage) {
        guard let model = runningModel, let i = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        var total = messages[i].usage ?? Usage()
        total.inputTokens += u.inputTokens; total.outputTokens += u.outputTokens; total.cacheReadTokens += u.cacheReadTokens
        messages[i].usage = total
        messages[i].model = model
        let settings = AppSettings.shared
        settings.recordSpend(settings.price(for: model)?.cost(u) ?? 0)
        switch Spend.check(task: spent.cost, day: settings.spentToday, limits: settings.spendLimits) {
        case .ok: break
        case .warn(let why): notice = why
        case .stop(let why): spendStop = why
        }
    }

    /// Tokens and cost of this task so far (own key).
    var spent: Spend.Total { Spend.total(messages, price: AppSettings.shared.price(for:)) }

    /// What the model sees: the summary of the older steps (if any), then the messages after it.
    static func history(_ all: [Message], start: Int, summary: String?) -> [Message] {
        guard let summary, start > 0, start <= all.count else { return all }
        return Compaction.prefix(summary) + all[start...]
    }

    private func clearLive() {
        liveText = ""
        liveThinking = ""
        liveTools = []
    }

    private func persist() {
        thread.messages = messages
    }
}

/// Prompts handed to a task that is about to open (e.g. "Investigate" on the server dashboard).
@MainActor
enum PendingPrompt {
    private static var prompts: [UUID: String] = [:]
    private static var access: [UUID: CLIAccess] = [:]
    static func set(_ prompt: String, for thread: UUID, access level: CLIAccess? = nil) {
        prompts[thread] = prompt
        access[thread] = level
    }
    static func take(for thread: UUID) -> (text: String, access: CLIAccess?)? {
        guard let text = prompts.removeValue(forKey: thread) else { return nil }
        return (text, access.removeValue(forKey: thread))
    }

    /// Text the composer of a new chat starts with, not sent (e.g. "Have a look at `app.py`: ").
    private static var drafts: [UUID: String] = [:]
    static func setDraft(_ text: String, for thread: UUID) { drafts[thread] = text }
    static func takeDraft(for thread: UUID) -> String? { drafts.removeValue(forKey: thread) }

    /// Pictures the composer of a new chat starts with (e.g. a screenshot of the app), not sent.
    private static var draftImages: [UUID: [Data]] = [:]
    static func setDraftImages(_ images: [Data], for thread: UUID) { draftImages[thread] = images }
    static func takeDraftImages(for thread: UUID) -> [Data] { draftImages.removeValue(forKey: thread) ?? [] }
}
