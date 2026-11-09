import Foundation

public enum ApprovalPolicy: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Every tool call waits for the user.
    case ask
    /// Reading is automatic, anything that changes the server waits for the user.
    case autoRead
    /// Everything runs without asking.
    case auto

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ask: "Ask every time"
        case .autoRead: "Ask before changes"
        case .auto: "Full auto"
        }
    }
}

public enum AgentEvent: Sendable, Hashable {
    case textDelta(String)
    case thinkingDelta(String)
    case toolCallStarted(id: String, name: String)
    case toolInputDelta(id: String, fragment: String)
    /// A finished assistant or tool-result message to append to the transcript.
    case message(Message)
    case toolRunning(ToolCall)
    case toolFinished(ToolCall, ToolResult)
    case usage(Usage)
    /// A server CLI started or resumed a session with this id.
    case sessionStarted(String)
    case finished(StopReason)
}

public enum ApprovalDecision: Sendable, Hashable {
    case allow
    case deny(reason: String?)
}

/// The agent loop: ask the model, run the tools it calls on the server, feed results back, repeat.
public struct Agent: Sendable {
    public var provider: any LLMProvider
    public var shell: any RemoteShell
    public var tools: [any AgentTool]
    public var policy: ApprovalPolicy
    public var system: String
    public var maxTurns: Int
    public var approve: @Sendable (ToolCall, _ readOnly: Bool) async -> ApprovalDecision

    public init(
        provider: any LLMProvider,
        shell: any RemoteShell,
        tools: [any AgentTool],
        policy: ApprovalPolicy,
        system: String,
        maxTurns: Int = 60,
        approve: @escaping @Sendable (ToolCall, Bool) async -> ApprovalDecision
    ) {
        self.provider = provider
        self.shell = shell
        self.tools = tools
        self.policy = policy
        self.system = system
        self.maxTurns = maxTurns
        self.approve = approve
    }

    public static func systemPrompt(host: String, user: String, workingDirectory: String, extra: String = "") -> String {
        """
        You are Deckhand, an engineering agent working on a Linux server for the user, who is on their phone.
        Server: \(user)@\(host). Workspace directory: \(workingDirectory).
        Your tools run on that server over SSH. Inspect before you change things, prefer small precise edits,
        and verify your work (build, test, curl, systemctl status…) before you say it is done.
        The user reads your replies on a small screen: keep them short, lead with the result, use Markdown sparingly.
        Never print secrets you come across. Ask before destructive or irreversible operations (deleting data,
        dropping databases, force pushes, rebooting) unless the user clearly asked for them.
        \(extra)
        """
    }

    /// Runs one user turn to completion. `history` is the conversation before `userMessage`.
    public func run(history: [Message], userMessage: Message) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await loop(history: history, userMessage: userMessage, emit: { continuation.yield($0) })
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.finished(.cancelled))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func loop(history: [Message], userMessage: Message, emit: (AgentEvent) -> Void) async throws {
        var messages = history + [userMessage]
        let specs = tools.map(\.spec)
        for _ in 0..<maxTurns {
            try Task.checkCancellation()
            var final: (Message, StopReason, Usage)?
            for try await event in provider.stream(ChatRequest(system: system, messages: messages, tools: specs)) {
                switch event {
                case .textDelta(let t): emit(.textDelta(t))
                case .thinkingDelta(let t): emit(.thinkingDelta(t))
                case .toolCallStarted(let id, let name): emit(.toolCallStarted(id: id, name: name))
                case .toolInputDelta(let id, let f): emit(.toolInputDelta(id: id, fragment: f))
                case .completed(let m, let s, let u): final = (m, s, u)
                }
            }
            guard let (assistant, stop, usage) = final else { throw LLMError.badStream("stream ended early") }
            messages.append(assistant)
            emit(.message(assistant))
            emit(.usage(usage))

            switch stop {
            case .pauseTurn:
                continue
            case .toolUse where !assistant.toolCalls.isEmpty:
                let results = await runTools(assistant.toolCalls, emit: emit)
                let resultMessage = Message(role: .user, blocks: results.map { .toolResult($0) })
                messages.append(resultMessage)
                emit(.message(resultMessage))
            case .maxTokens where !assistant.toolCalls.isEmpty:
                // A tool input cut off at max_tokens may parse as a valid partial object: never run it.
                let results = assistant.toolCalls.map {
                    ToolResult(toolUseID: $0.id, content: "Not run: output limit reached mid-call. Retry with smaller steps.", isError: true)
                }
                let resultMessage = Message(role: .user, blocks: results.map { .toolResult($0) })
                messages.append(resultMessage)
                emit(.message(resultMessage))
            default:
                emit(.finished(stop))
                return
            }
        }
        emit(.finished(.other))
    }

    private func runTools(_ calls: [ToolCall], emit: (AgentEvent) -> Void) async -> [ToolResult] {
        var results: [ToolResult] = []
        for call in calls {
            if Task.isCancelled {
                results.append(ToolResult(toolUseID: call.id, content: "Cancelled by the user.", isError: true))
                continue
            }
            let result = await runTool(call, emit: emit)
            emit(.toolFinished(call, result))
            results.append(result)
        }
        return results
    }

    private func runTool(_ call: ToolCall, emit: (AgentEvent) -> Void) async -> ToolResult {
        guard let tool = tools.first(where: { $0.spec.name == call.name }) else {
            return ToolResult(toolUseID: call.id, content: "Unknown tool \(call.name).", isError: true)
        }
        if let raw = call.input["INVALID_JSON"]?.stringValue {
            return ToolResult(toolUseID: call.id, content: "{\"INVALID_JSON\": \(JSONValue.string(raw).jsonString())}", isError: true)
        }
        let needsApproval = switch policy {
        case .ask: true
        case .autoRead: !tool.isReadOnly
        case .auto: false
        }
        if needsApproval {
            switch await approve(call, tool.isReadOnly) {
            case .allow: break
            case .deny(let reason):
                let why = reason.map { " Reason: \($0)" } ?? ""
                return ToolResult(toolUseID: call.id, content: "The user declined this tool call.\(why)", isError: true)
            }
        }
        emit(.toolRunning(call))
        do {
            let output = try await tool.execute(call.input, shell: shell)
            return ToolResult(toolUseID: call.id, content: output)
        } catch {
            return ToolResult(toolUseID: call.id, content: error.localizedDescription, isError: true)
        }
    }
}
