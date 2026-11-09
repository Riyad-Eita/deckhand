import Foundation

/// Claude via the Messages API (raw HTTP + SSE).
public struct AnthropicProvider: LLMProvider {
    public static let apiVersion = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    public let config: ProviderConfig
    let session: URLSession

    public init(config: ProviderConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        guard !config.apiKey.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: LLMError.missingAPIKey) }
        }
        let urlRequest: URLRequest
        do { urlRequest = try makeURLRequest(request) } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return decodeStream(session.serverSentEvents(for: urlRequest), decoder: AnthropicStreamDecoder())
    }

    /// Server-side refusal fallback is offered for the Opus/Sonnet/Fable lines, not for Haiku.
    var usesFallback: Bool {
        config.baseURL.host == "api.anthropic.com" && !config.model.contains("haiku")
    }

    func makeURLRequest(_ request: ChatRequest) throws -> URLRequest {
        var r = URLRequest(url: config.baseURL.appending(path: "v1/messages"))
        r.httpMethod = "POST"
        r.timeoutInterval = 600
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if usesFallback { r.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        r.httpBody = try body(for: request).jsonData()
        return r
    }

    func body(for request: ChatRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(config.model),
            "max_tokens": .number(Double(request.maxTokens)),
            "stream": true,
            "thinking": ["type": "adaptive", "display": "summarized"],
            "messages": .array(request.messages.map(Self.encode)),
        ]
        if !request.system.isEmpty {
            body["system"] = [["type": "text", "text": .string(request.system), "cache_control": ["type": "ephemeral"]]]
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                [
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.inputSchema,
                    "eager_input_streaming": true,
                ]
            })
        }
        if let effort = config.effort { body["output_config"] = ["effort": .string(effort)] }
        if usesFallback { body["fallbacks"] = "default" }
        // Cache the growing conversation prefix.
        body["cache_control"] = ["type": "ephemeral"]
        return .object(body)
    }

    static func encode(_ message: Message) -> JSONValue {
        let blocks: [JSONValue] = message.blocks.compactMap { block in
            switch block {
            case .text(let t):
                return t.isEmpty ? nil : ["type": "text", "text": .string(t)]
            case .thinking(let text, let signature):
                var b: [String: JSONValue] = ["type": "thinking", "thinking": .string(text)]
                if let signature { b["signature"] = .string(signature) }
                return .object(b)
            case .toolUse(let call):
                return ["type": "tool_use", "id": .string(call.id), "name": .string(call.name), "input": call.input]
            case .toolResult(let result):
                return [
                    "type": "tool_result", "tool_use_id": .string(result.toolUseID),
                    "content": .string(result.content), "is_error": .bool(result.isError),
                ]
            case .opaque(let provider, let value):
                return provider == "anthropic" ? value : nil
            }
        }
        return ["role": .string(message.role.rawValue), "content": .array(blocks)]
    }
}

/// Turns Messages API stream events into provider events and the final message.
struct AnthropicStreamDecoder: StreamDecoder {
    private enum Partial {
        case text(String)
        case thinking(String, signature: String?)
        case toolUse(id: String, name: String, json: String)
        case opaque(JSONValue)
    }

    private var blocks: [Int: Partial] = [:]
    private var stopReason: StopReason = .endTurn
    private var usage = Usage()
    private(set) var isFinished = false

    mutating func consume(_ event: SSEParser.Event) throws -> [ProviderEvent] {
        guard let json = try? JSONValue.parse(event.data), let type = json["type"]?.stringValue else { return [] }
        switch type {
        case "message_start":
            if let u = json["message"]?["usage"] { merge(usage: u) }
        case "content_block_start":
            guard let index = json["index"]?.intValue, let block = json["content_block"] else { return [] }
            switch block["type"]?.stringValue {
            case "text":
                let text = block["text"]?.stringValue ?? ""
                blocks[index] = .text(text)
                return text.isEmpty ? [] : [.textDelta(text)]
            case "thinking":
                blocks[index] = .thinking(block["thinking"]?.stringValue ?? "", signature: block["signature"]?.stringValue)
            case "tool_use":
                let id = block["id"]?.stringValue ?? UUID().uuidString
                let name = block["name"]?.stringValue ?? ""
                blocks[index] = .toolUse(id: id, name: name, json: "")
                return [.toolCallStarted(id: id, name: name)]
            default:
                // redacted_thinking, fallback markers, server tool blocks: keep verbatim.
                blocks[index] = .opaque(block)
            }
        case "content_block_delta":
            guard let index = json["index"]?.intValue, let delta = json["delta"], let current = blocks[index] else { return [] }
            switch (delta["type"]?.stringValue, current) {
            case ("text_delta", .text(let t)):
                let piece = delta["text"]?.stringValue ?? ""
                blocks[index] = .text(t + piece)
                return [.textDelta(piece)]
            case ("thinking_delta", .thinking(let t, let sig)):
                let piece = delta["thinking"]?.stringValue ?? ""
                blocks[index] = .thinking(t + piece, signature: sig)
                return [.thinkingDelta(piece)]
            case ("signature_delta", .thinking(let t, let sig)):
                blocks[index] = .thinking(t, signature: (sig ?? "") + (delta["signature"]?.stringValue ?? ""))
            case ("input_json_delta", .toolUse(let id, let name, let partial)):
                let piece = delta["partial_json"]?.stringValue ?? ""
                blocks[index] = .toolUse(id: id, name: name, json: partial + piece)
                return [.toolInputDelta(id: id, fragment: piece)]
            default:
                break
            }
        case "message_delta":
            if let reason = json["delta"]?["stop_reason"]?.stringValue { stopReason = Self.map(reason) }
            if let u = json["usage"] { merge(usage: u) }
        case "message_stop":
            isFinished = true
        case "error":
            let message = json["error"]?["message"]?.stringValue ?? event.data
            throw LLMError.badStream(message)
        default:
            break
        }
        return []
    }

    mutating func finish() throws -> [ProviderEvent] {
        let content: [ContentBlock] = blocks.keys.sorted().compactMap { index in
            switch blocks[index]! {
            case .text(let t): return .text(t)
            case .thinking(let t, let sig): return .thinking(text: t, signature: sig)
            case .toolUse(let id, let name, let json):
                // Inputs stream eagerly and are not validated server-side: parse strictly.
                let input = (try? JSONValue.parse(json.isEmpty ? "{}" : json)) ?? .object(["INVALID_JSON": .string(json)])
                return .toolUse(ToolCall(id: id, name: name, input: input))
            case .opaque(let value): return .opaque(provider: "anthropic", value: value)
            }
        }
        return [.completed(Message(role: .assistant, blocks: content), stopReason, usage)]
    }

    private mutating func merge(usage u: JSONValue) {
        if let n = u["input_tokens"]?.intValue { usage.inputTokens = n }
        if let n = u["output_tokens"]?.intValue { usage.outputTokens = n }
        if let n = u["cache_read_input_tokens"]?.intValue { usage.cacheReadTokens = n }
    }

    static func map(_ reason: String) -> StopReason {
        switch reason {
        case "end_turn", "stop_sequence": .endTurn
        case "tool_use": .toolUse
        case "max_tokens": .maxTokens
        case "refusal": .refusal
        case "pause_turn": .pauseTurn
        default: .other
        }
    }
}
