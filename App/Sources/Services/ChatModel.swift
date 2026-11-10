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
    private(set) var error: String?
    /// Non-fatal information for the current run (e.g. a connection that could not be opened).
    private(set) var notice: String?
    private(set) var usage = Usage()
    var pendingApproval: PendingApproval?
    private var task: Task<Void, Never>?
    private var waitingForLimit = false
    private var waitingLine = 0

    init(thread: ChatThread, server: Server) {
        self.thread = thread
        self.server = server
        self.messages = thread.messages
    }

    /// A server run that was going when the app closed or the connection dropped: pick it up again.
    func resumeIfNeeded() {
        guard !isRunning, thread.cliRunActive, let id = thread.cliRunID, let cli = thread.engine.serverCLI else { return }
        isRunning = true
        notice = String(localized: "Reattaching to the run on the server…")
        task = Task { await follow(cli, run: DetachedRun(id: id), prompt: "", access: AppSettings.shared.cliAccess) }
    }

    /// Reads a detached server run until it ends; reconnects and continues from the last line if the connection drops.
    private func follow(_ cli: ServerCLI, run: DetachedRun, prompt: String, access: CLIAccess) async {
        var delay: Double = 2
        var reconnecting = thread.cliRunLine > 1
        let starting = thread.cliRunLine <= 1
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
                    sessionID: thread.cliSessionID, access: access, run: run, fromLine: thread.cliRunLine,
                    meta: DetachedRun.Meta(title: thread.title, engine: cli.displayName, directory: thread.workingDirectory),
                    notify: notify)
                for try await event in events {
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
        }
        clearLive()
        isRunning = false
        persist()
    }

    func result(for callID: String) -> ToolResult? {
        for message in messages {
            for case .toolResult(let r) in message.blocks where r.toolUseID == callID { return r }
        }
        return nil
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        let settings = AppSettings.shared
        guard thread.engine != .ownKey || settings.isConfigured else {
            error = LLMError.missingAPIKey.localizedDescription
            return
        }
        error = nil
        notice = nil
        let user = Message.user(trimmed)
        let history = messages
        messages.append(user)
        if history.isEmpty { thread.title = String(trimmed.prefix(60)) }
        persist()
        isRunning = true
        runStartedAt = Date()
        let config = settings.providerConfig
        let policy = settings.approvalPolicy
        let access = settings.cliAccess
        task = Task {
            do {
                let shell = try await Connections.shared.connection(for: server)
                if let cli = thread.engine.serverCLI {
                    let run = DetachedRun()
                    thread.cliRunID = run.id
                    thread.cliRunLine = 1
                    thread.cliRunActive = true
                    await follow(cli, run: run, prompt: trimmed, access: access)
                    return
                }
                let records = (try? thread.modelContext?.fetch(FetchDescriptor<ConnectionRecord>())) ?? []
                let mcp = await MCPConnector.open(records.map { ($0.spec, $0.token) }, server: shell)
                defer { Task { await mcp.close() } }
                if !mcp.failures.isEmpty {
                    notice = "Not available this time: " + mcp.failures.map { "\($0.name) (\($0.error))" }.joined(separator: ", ")
                }
                let agent = Agent(
                    provider: Providers.make(config),
                    shell: shell,
                    tools: ServerTools.all(workingDirectory: thread.workingDirectory) + mcp.tools,
                    policy: policy,
                    system: Agent.systemPrompt(host: server.host, user: server.username, workingDirectory: thread.workingDirectory),
                    approve: { [weak self] request in
                        await self?.requestApproval(request) ?? .deny(reason: nil)
                    })
                for try await event in agent.run(history: history, userMessage: user) {
                    handle(event)
                }
            } catch {
                self.error = error.localizedDescription
            }
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
        return await withCheckedContinuation { continuation in
            pendingApproval = PendingApproval(call: request.call, danger: request.danger) { [weak self] decision in
                self?.pendingApproval = nil
                continuation.resume(returning: decision)
            }
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
            messages.append(message)
            clearLive()
            persist()
        case .toolRunning(let call): toolStatus[call.id] = .running
        case .toolFinished(let call, let result): toolStatus[call.id] = .done(result)
        case .checkpoint(let line):
            thread.cliRunLine = line
            if waitingForLimit, line > waitingLine { waitingForLimit = false; notice = nil }
        case .waitingForLimit(let until):
            waitingForLimit = true
            waitingLine = thread.cliRunLine + 1
            let time = until.formatted(Calendar.current.isDateInToday(until) ? .dateTime.hour().minute() : .dateTime.weekday().hour().minute())
            notice = String(localized: "Usage limit reached. The task waits on the server and continues at \(time) by itself — you can close the app.")
        case .sessionStarted(let id):
            thread.cliSessionID = id
        case .usage(let u):
            usage.inputTokens += u.inputTokens
            usage.outputTokens += u.outputTokens
        case .finished(let reason):
            switch reason {
            case .refusal: error = "The model declined this request."
            case .maxTokens: error = "The reply hit the output limit."
            default: break
            }
        }
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
    static func set(_ prompt: String, for thread: UUID) { prompts[thread] = prompt }
    static func take(for thread: UUID) -> String? { prompts.removeValue(forKey: thread) }
}
