import Foundation

/// Coding agents that run on the server under the user's own subscription.
public enum ServerCLI: String, Sendable, Codable, CaseIterable, Identifiable {
    case codex
    case claudeCode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }

    public var executable: String {
        switch self {
        case .codex: "codex"
        case .claudeCode: "claude"
        }
    }

    /// Installs or updates into ~/.local without root (official installers / npm with a user prefix).
    public var installCommand: String {
        switch self {
        case .codex:
            "mkdir -p ~/.local/bin && npm install -g --prefix ~/.local @openai/codex@latest"
        case .claudeCode:
            "curl -fsSL https://claude.ai/install.sh | bash"
        }
    }

    /// Prints something containing "logged in"/"Logged in" when authenticated.
    public var statusCommand: String {
        switch self {
        case .codex: "codex login status 2>&1"
        case .claudeCode: "claude auth status 2>&1"
        }
    }
}

/// How much a server CLI may do without asking (headless runs cannot ask interactively).
public enum CLIAccess: String, Sendable, Codable, CaseIterable, Identifiable {
    case readOnly
    case edit
    case full

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .readOnly: "Read only"
        case .edit: "Edit files"
        case .full: "Full access"
        }
    }
}

public enum ServerCLIRun {
    /// The shell command for one headless turn. `sessionID` continues an earlier conversation.
    public static func command(
        _ cli: ServerCLI, prompt: String, workingDirectory: String, sessionID: String?, access: CLIAccess, options: CLIOptions = .init()
    ) -> String {
        let dir = ServerTools.shellPath(workingDirectory)
        let p = ShellQuote.quote(prompt)
        switch cli {
        case .codex:
            let sandbox = switch access {
            case .readOnly: "read-only"
            case .edit: "workspace-write"
            case .full: "danger-full-access"
            }
            var cmd = "cd \(dir) && codex exec --json --skip-git-repo-check -s \(sandbox)" + CLIModels.flags(cli, options)
            if let sessionID { cmd += " resume \(ShellQuote.quote(sessionID))" }
            return cmd + " \(p) < /dev/null"
        case .claudeCode:
            let mode = switch access {
            case .readOnly: "plan"
            case .edit: "acceptEdits"
            case .full: "bypassPermissions"
            }
            var cmd = "cd \(dir) && claude -p \(p) --output-format stream-json --verbose --permission-mode \(mode)" + CLIModels.flags(cli, options)
            if let sessionID { cmd += " --resume \(ShellQuote.quote(sessionID))" }
            return cmd + " < /dev/null"
        }
    }

    /// Runs one turn detached from the connection: it keeps going on the server if the phone disconnects.
    /// Pass `fromLine` > 1 to reattach to a run that is already going; nothing is started then.
    public static func runDetached(
        _ cli: ServerCLI, shell: any StreamingShell, prompt: String, workingDirectory: String,
        sessionID: String?, access: CLIAccess, options: CLIOptions = .init(), run: DetachedRun, fromLine: Int = 1,
        meta: DetachedRun.Meta? = nil, notify: DetachedRun.Notify? = nil
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let cliCommand = LimitAwareRun.command(
            cli, prompt: prompt, workingDirectory: workingDirectory, sessionID: sessionID, access: access, options: options, run: run)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var decoder: any CLIEventDecoder = cli == .codex ? CodexEventDecoder() : ClaudeCodeEventDecoder()
                do {
                    if fromLine <= 1 {
                        let started = try await shell.run(run.startCommand(cliCommand, meta: meta, notify: notify), timeout: .seconds(30))
                        guard started.stdout.contains("started") else { throw CLIError("Couldn't start \(cli.displayName) on the server.") }
                    }
                    var line = max(1, fromLine)
                    var exit: Int32?
                    for try await text in shell.streamLines(run.readCommand(fromLine: line)) {
                        switch DetachedRun.marker(text) {
                        case .exit(let code): exit = code
                        case .missing: throw CLIError("This run is no longer on the server.")
                        case nil:
                            for event in try decoder.consume(line: text) { continuation.yield(event) }
                            line += 1
                            continuation.yield(.checkpoint(line))
                        }
                    }
                    guard exit != nil else { throw CLIError("Lost the connection to the run.") }
                    if exit == 143 { continuation.yield(.finished(.cancelled)) } else {
                        for event in try decoder.finish() { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: decoder.failure ?? error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs one turn and translates the CLI's JSON lines into agent events.
    public static func run(
        _ cli: ServerCLI, shell: any StreamingShell, prompt: String, workingDirectory: String,
        sessionID: String?, access: CLIAccess
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let command = command(cli, prompt: prompt, workingDirectory: workingDirectory, sessionID: sessionID, access: access)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var decoder: any CLIEventDecoder = cli == .codex ? CodexEventDecoder() : ClaudeCodeEventDecoder()
                do {
                    for try await line in shell.streamLines(command) {
                        for event in try decoder.consume(line: line) { continuation.yield(event) }
                    }
                    for event in try decoder.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.finished(.cancelled))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: decoder.failure ?? error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct CLIError: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    /// Looked up in the app's string catalog by its English text (falls back to it).
    public var errorDescription: String? { String(localized: String.LocalizationValue(message)) }
}

/// Lines the limit-aware wrapper adds to the CLI's output (see `LimitAwareRun`).
enum WrapperLine {
    case waiting(Date)
    case resumed

    static func parse(_ json: JSONValue) -> WrapperLine? {
        switch json["type"]?.stringValue {
        case "deckhand.waiting": .waiting(Date(timeIntervalSince1970: json["until"]?.doubleValue ?? 0))
        case "deckhand.resumed": .resumed
        default: nil
        }
    }
}

protocol CLIEventDecoder: Sendable {
    /// The CLI's own error message, if it reported one before failing.
    var failure: CLIError? { get }
    mutating func consume(line: String) throws -> [AgentEvent]
    mutating func finish() throws -> [AgentEvent]
}

extension JSONValue {
    fileprivate var objectOrEmpty: JSONValue { objectValue == nil ? .object([:]) : self }
}

// MARK: - Codex (`codex exec --json`)

struct CodexEventDecoder: CLIEventDecoder {
    private var started: [String: ToolCall] = [:]
    private var finished = false
    private(set) var failure: CLIError?

    mutating func consume(line: String) throws -> [AgentEvent] {
        guard let json = try? JSONValue.parse(line), let type = json["type"]?.stringValue else { return [] }
        switch WrapperLine.parse(json) {
        case .waiting(let until): failure = nil; return [.waitingForLimit(until: until)]
        case .resumed: failure = nil; finished = false; return []
        case nil: break
        }
        switch type {
        case "thread.started":
            return json["thread_id"]?.stringValue.map { [.sessionStarted($0)] } ?? []
        case "item.started":
            guard let item = json["item"], let call = Self.toolCall(for: item) else { return [] }
            started[call.id] = call
            return [.message(Message(role: .assistant, blocks: [.toolUse(call)])), .toolRunning(call)]
        case "item.completed":
            guard let item = json["item"] else { return [] }
            switch item["type"]?.stringValue {
            case "agent_message":
                let text = item["text"]?.stringValue ?? ""
                return text.isEmpty ? [] : [.message(Message(role: .assistant, blocks: [.text(text)]))]
            case "reasoning":
                let text = item["text"]?.stringValue ?? ""
                return text.isEmpty ? [] : [.message(Message(role: .assistant, blocks: [.thinking(text: text, signature: nil)]))]
            default:
                guard let call = Self.toolCall(for: item) else { return [] }
                var events: [AgentEvent] = []
                if started.removeValue(forKey: call.id) == nil {
                    events.append(.message(Message(role: .assistant, blocks: [.toolUse(call)])))
                }
                let result = Self.result(for: item, callID: call.id)
                events.append(.toolFinished(call, result))
                events.append(.message(Message(role: .user, blocks: [.toolResult(result)])))
                return events
            }
        case "turn.completed":
            finished = true
            failure = nil
            let u = json["usage"]
            return [
                .usage(Usage(
                    inputTokens: u?["input_tokens"]?.intValue ?? 0,
                    outputTokens: u?["output_tokens"]?.intValue ?? 0,
                    cacheReadTokens: u?["cached_input_tokens"]?.intValue ?? 0)),
                .finished(.endTurn),
            ]
        case "turn.failed":
            let message = json["error"]?["message"]?.stringValue ?? "Codex failed."
            // Reported when the stream ends: a limit-aware run may still wait and continue after this.
            failure = CLIError(Self.friendly(message))
        case "error":
            let message = json["message"]?.stringValue ?? ""
            if !message.hasPrefix("Re-connecting") { failure = CLIError(Self.friendly(message)) }
        default:
            break
        }
        return []
    }

    mutating func finish() throws -> [AgentEvent] {
        if let failure { throw failure }
        if finished { return [] }
        return [.finished(.other)]
    }

    static func friendly(_ message: String) -> String {
        if message.contains("requires a newer version of Codex") {
            return "Codex on the server is too old for this model. Update it from the server's CLI settings."
        }
        return message
    }

    static func toolCall(for item: JSONValue) -> ToolCall? {
        guard let id = item["id"]?.stringValue, let type = item["type"]?.stringValue else { return nil }
        switch type {
        case "agent_message", "reasoning":
            return nil
        case "command_execution":
            return ToolCall(id: id, name: "run_command", input: ["command": .string(Self.unwrap(item["command"]?.stringValue ?? ""))])
        case "file_change":
            let paths = (item["changes"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
            return ToolCall(id: id, name: "file_change", input: ["paths": .array(paths.map { .string($0) })])
        default:
            return ToolCall(id: id, name: type, input: item)
        }
    }

    /// `/bin/bash -lc 'uname -r'` → `uname -r`
    static func unwrap(_ command: String) -> String {
        for prefix in ["/bin/bash -lc ", "bash -lc ", "/bin/sh -c ", "sh -c "] where command.hasPrefix(prefix) {
            var rest = String(command.dropFirst(prefix.count))
            if rest.hasPrefix("'"), rest.hasSuffix("'"), rest.count >= 2 {
                rest = String(rest.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
            } else if rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 {
                var out = ""
                var escaped = false
                for ch in rest.dropFirst().dropLast() {
                    if escaped {
                        if !"\"\\$`".contains(ch) { out.append("\\") }
                        out.append(ch)
                        escaped = false
                    } else if ch == "\\" {
                        escaped = true
                    } else {
                        out.append(ch)
                    }
                }
                rest = out
            }
            return rest
        }
        return command
    }

    static func result(for item: JSONValue, callID: String) -> ToolResult {
        switch item["type"]?.stringValue {
        case "command_execution":
            let code = item["exit_code"]?.intValue
            let output = item["aggregated_output"]?.stringValue ?? ""
            let failed = (code ?? 0) != 0 || item["status"]?.stringValue == "failed"
            return ToolResult(toolUseID: callID, content: "exit code: \(code.map(String.init) ?? "?")\n\(output)", isError: failed)
        case "file_change":
            let lines = (item["changes"]?.arrayValue ?? []).map {
                "\($0["kind"]?.stringValue ?? "update") \($0["path"]?.stringValue ?? "")"
            }
            return ToolResult(toolUseID: callID, content: lines.joined(separator: "\n"), isError: item["status"]?.stringValue == "failed")
        default:
            return ToolResult(toolUseID: callID, content: item.jsonString(), isError: item["status"]?.stringValue == "failed")
        }
    }
}

// MARK: - Claude Code (`claude -p --output-format stream-json --verbose`)

struct ClaudeCodeEventDecoder: CLIEventDecoder {
    private var calls: [String: ToolCall] = [:]
    private var finished = false
    private(set) var failure: CLIError?

    mutating func consume(line: String) throws -> [AgentEvent] {
        guard let json = try? JSONValue.parse(line), let type = json["type"]?.stringValue else { return [] }
        switch WrapperLine.parse(json) {
        case .waiting(let until): failure = nil; return [.waitingForLimit(until: until)]
        case .resumed: failure = nil; finished = false; return []
        case nil: break
        }
        switch type {
        case "system":
            if json["subtype"]?.stringValue == "init", let id = json["session_id"]?.stringValue { return [.sessionStarted(id)] }
        case "assistant":
            var blocks: [ContentBlock] = []
            var running: [ToolCall] = []
            for block in json["message"]?["content"]?.arrayValue ?? [] {
                switch block["type"]?.stringValue {
                case "text":
                    if let t = block["text"]?.stringValue, !t.isEmpty { blocks.append(.text(t)) }
                case "thinking":
                    if let t = block["thinking"]?.stringValue, !t.isEmpty { blocks.append(.thinking(text: t, signature: nil)) }
                case "tool_use":
                    let call = Self.normalize(
                        id: block["id"]?.stringValue ?? UUID().uuidString,
                        name: block["name"]?.stringValue ?? "tool",
                        input: block["input"]?.objectOrEmpty ?? .object([:]))
                    calls[call.id] = call
                    blocks.append(.toolUse(call))
                    running.append(call)
                default:
                    break
                }
            }
            guard !blocks.isEmpty else { return [] }
            return [.message(Message(role: .assistant, blocks: blocks))] + running.map { .toolRunning($0) }
        case "user":
            var events: [AgentEvent] = []
            var results: [ContentBlock] = []
            for block in json["message"]?["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_result" {
                let id = block["tool_use_id"]?.stringValue ?? ""
                let content: String
                if let s = block["content"]?.stringValue { content = s } else {
                    content = (block["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                }
                let result = ToolResult(toolUseID: id, content: content, isError: block["is_error"]?.boolValue ?? false)
                if let call = calls[id] { events.append(.toolFinished(call, result)) }
                results.append(.toolResult(result))
            }
            if !results.isEmpty { events.append(.message(Message(role: .user, blocks: results))) }
            return events
        case "result":
            finished = true
            let u = json["usage"]
            var events: [AgentEvent] = [.usage(Usage(
                inputTokens: u?["input_tokens"]?.intValue ?? 0,
                outputTokens: u?["output_tokens"]?.intValue ?? 0,
                cacheReadTokens: u?["cache_read_input_tokens"]?.intValue ?? 0))]
            if json["is_error"]?.boolValue == true {
                let message = json["result"]?.stringValue ?? json["subtype"]?.stringValue ?? "Claude Code failed."
                // Reported when the stream ends: a limit-aware run may still wait and continue after this.
                failure = CLIError(Self.friendly(message))
                finished = false
                return events
            }
            failure = nil
            events.append(.finished(.endTurn))
            return events
        default:
            break
        }
        return []
    }

    mutating func finish() throws -> [AgentEvent] {
        if finished { return [] }
        if let failure { throw failure }
        throw CLIError("Claude Code stopped without a result. Is it installed and logged in on the server?")
    }

    static func friendly(_ message: String) -> String {
        if message.contains("/login") || message.contains("Invalid API key") {
            return "Claude Code on the server is not logged in. Log in from the server's CLI settings."
        }
        return message
    }

    /// Maps Claude Code's tool names onto the app's tool vocabulary so the cards look the same.
    static func normalize(id: String, name: String, input: JSONValue) -> ToolCall {
        func s(_ k: String) -> JSONValue { input[k] ?? .string("") }
        switch name {
        case "Bash": return ToolCall(id: id, name: "run_command", input: ["command": s("command")])
        case "Read": return ToolCall(id: id, name: "read_file", input: ["path": s("file_path")])
        case "Write": return ToolCall(id: id, name: "write_file", input: ["path": s("file_path"), "content": s("content")])
        case "Edit", "MultiEdit":
            return ToolCall(id: id, name: "edit_file", input: [
                "path": s("file_path"), "old_string": s("old_string"), "new_string": s("new_string"),
            ])
        case "Grep": return ToolCall(id: id, name: "search", input: ["pattern": s("pattern")])
        case "Glob": return ToolCall(id: id, name: "search", input: ["pattern": s("pattern")])
        case "LS": return ToolCall(id: id, name: "list_directory", input: ["path": s("path")])
        default: return ToolCall(id: id, name: name, input: input)
        }
    }
}
