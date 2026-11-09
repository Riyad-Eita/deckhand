import DeckhandCore
import DeckhandSSH
import Foundation
import Observation

/// Drives one agent conversation: streams model output, shows tool calls, asks for approvals.
@MainActor
@Observable
final class ChatModel {
    struct PendingApproval: Identifiable {
        let id = UUID()
        let call: ToolCall
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
    private(set) var isRunning = false
    private(set) var error: String?
    private(set) var usage = Usage()
    var pendingApproval: PendingApproval?
    private var task: Task<Void, Never>?

    init(thread: ChatThread, server: Server) {
        self.thread = thread
        self.server = server
        self.messages = thread.messages
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
        guard settings.isConfigured else {
            error = LLMError.missingAPIKey.localizedDescription
            return
        }
        error = nil
        let user = Message.user(trimmed)
        let history = messages
        messages.append(user)
        if history.isEmpty { thread.title = String(trimmed.prefix(60)) }
        persist()
        isRunning = true
        let config = settings.providerConfig
        let policy = settings.approvalPolicy
        task = Task {
            do {
                let shell = try await Connections.shared.connection(for: server)
                let agent = Agent(
                    provider: Providers.make(config),
                    shell: shell,
                    tools: ServerTools.all(workingDirectory: thread.workingDirectory),
                    policy: policy,
                    system: Agent.systemPrompt(host: server.host, user: server.username, workingDirectory: thread.workingDirectory),
                    approve: { [weak self] call, _ in
                        await self?.requestApproval(call) ?? .deny(reason: nil)
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
        task?.cancel()
        pendingApproval?.respond(.deny(reason: "Stopped by the user."))
    }

    private func requestApproval(_ call: ToolCall) async -> ApprovalDecision {
        toolStatus[call.id] = .waiting
        return await withCheckedContinuation { continuation in
            pendingApproval = PendingApproval(call: call) { [weak self] decision in
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
