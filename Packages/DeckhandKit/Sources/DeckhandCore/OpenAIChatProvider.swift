import Foundation

/// Any endpoint that speaks the OpenAI Chat Completions API: OpenAI, OpenRouter, Ollama, vLLM, LM Studio, Groq…
public struct OpenAIChatProvider: LLMProvider {
    public let config: ProviderConfig
    let session: URLSession

    public init(config: ProviderConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        if config.apiKey.isEmpty && config.kind != .custom {
            return AsyncThrowingStream { $0.finish(throwing: LLMError.missingAPIKey) }
        }
        let urlRequest: URLRequest
        do { urlRequest = try makeURLRequest(request) } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return decodeStream(session.serverSentEvents(for: urlRequest), decoder: OpenAIChatStreamDecoder())
    }

    func makeURLRequest(_ request: ChatRequest) throws -> URLRequest {
        var r = URLRequest(url: config.baseURL.appending(path: "chat/completions"))
        r.httpMethod = "POST"
        r.timeoutInterval = 600
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        if !config.apiKey.isEmpty { r.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "authorization") }
        if config.kind == .openRouter {
            r.setValue("https://github.com/Riyad-Eita/deckhand", forHTTPHeaderField: "HTTP-Referer")
            r.setValue("Deckhand", forHTTPHeaderField: "X-Title")
        }
        r.httpBody = try body(for: request).jsonData()
        return r
    }

    func body(for request: ChatRequest) -> JSONValue {
        var messages: [JSONValue] = []
        if !request.system.isEmpty { messages.append(["role": "system", "content": .string(request.system)]) }
        for message in request.messages { messages.append(contentsOf: Self.encode(message)) }
        var body: [String: JSONValue] = [
            "model": .string(config.model),
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": .array(messages),
        ]
        if config.kind == .openAI {
            body["max_completion_tokens"] = .number(Double(min(request.maxTokens, 32_000)))
            if let effort = config.effort { body["reasoning_effort"] = .string(effort == "max" ? "high" : effort) }
        } else {
            body["max_tokens"] = .number(Double(min(request.maxTokens, 32_000)))
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.inputSchema,
                    ],
                ]
            })
        }
        return .object(body)
    }

    /// One app message can become several Chat Completions messages (tool results are separate `tool` messages).
    static func encode(_ message: Message) -> [JSONValue] {
        switch message.role {
        case .assistant:
            var m: [String: JSONValue] = ["role": "assistant", "content": .string(message.text)]
            let calls = message.toolCalls
            if !calls.isEmpty {
                m["tool_calls"] = .array(calls.map { call in
                    [
                        "id": .string(call.id), "type": "function",
                        "function": ["name": .string(call.name), "arguments": .string(call.input.jsonString())],
                    ]
                })
            }
            return [.object(m)]
        case .user:
            var out: [JSONValue] = []
            var text = ""
            var images: [JSONValue] = []
            for block in message.blocks {
                switch block {
                case .toolResult(let r):
                    let content = r.isError ? "ERROR: \(r.content)" : r.content
                    out.append(["role": "tool", "tool_call_id": .string(r.toolUseID), "content": .string(content)])
                case .text(let t): text += t
                case .image(let type, let data):
                    images.append(["type": "image_url", "image_url": ["url": .string("data:\(type);base64,\(data.base64EncodedString())")]])
                default: break
                }
            }
            if !images.isEmpty {
                out.append(["role": "user", "content": .array((text.isEmpty ? [] : [["type": "text", "text": .string(text)]]) + images)])
            } else if !text.isEmpty {
                out.append(["role": "user", "content": .string(text)])
            }
            return out
        }
    }
}

struct OpenAIChatStreamDecoder: StreamDecoder {
    private struct PartialCall { var id: String; var name: String; var arguments: String }

    private var text = ""
    private var reasoning = ""
    private var calls: [Int: PartialCall] = [:]
    private var finishReason: String?
    private var usage = Usage()
    private(set) var isFinished = false

    mutating func consume(_ event: SSEParser.Event) throws -> [ProviderEvent] {
        if event.data == "[DONE]" { isFinished = true; return [] }
        guard let json = try? JSONValue.parse(event.data) else { return [] }
        if let error = json["error"] {
            throw LLMError.badStream(error["message"]?.stringValue ?? event.data)
        }
        if let u = json["usage"], u != .null {
            usage.inputTokens = u["prompt_tokens"]?.intValue ?? usage.inputTokens
            usage.outputTokens = u["completion_tokens"]?.intValue ?? usage.outputTokens
            usage.cacheReadTokens = u["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? usage.cacheReadTokens
        }
        guard let choice = json["choices"]?.arrayValue?.first else { return [] }
        if let reason = choice["finish_reason"]?.stringValue { finishReason = reason }
        guard let delta = choice["delta"] else { return [] }
        var out: [ProviderEvent] = []
        for key in ["reasoning_content", "reasoning"] {
            if let r = delta[key]?.stringValue, !r.isEmpty { reasoning += r; out.append(.thinkingDelta(r)) }
        }
        if let t = delta["content"]?.stringValue, !t.isEmpty {
            text += t
            out.append(.textDelta(t))
        }
        for call in delta["tool_calls"]?.arrayValue ?? [] {
            let index = call["index"]?.intValue ?? 0
            var partial = calls[index] ?? PartialCall(id: "", name: "", arguments: "")
            let isNew = calls[index] == nil
            if let id = call["id"]?.stringValue, !id.isEmpty { partial.id = id }
            if let name = call["function"]?["name"]?.stringValue, !name.isEmpty { partial.name += name }
            if partial.id.isEmpty { partial.id = "call_\(index)_\(UUID().uuidString.prefix(8))" }
            if isNew { out.append(.toolCallStarted(id: partial.id, name: partial.name)) }
            if let args = call["function"]?["arguments"]?.stringValue, !args.isEmpty {
                partial.arguments += args
                out.append(.toolInputDelta(id: partial.id, fragment: args))
            }
            calls[index] = partial
        }
        return out
    }

    mutating func finish() throws -> [ProviderEvent] {
        var blocks: [ContentBlock] = []
        if !reasoning.isEmpty { blocks.append(.thinking(text: reasoning, signature: nil)) }
        if !text.isEmpty { blocks.append(.text(text)) }
        for index in calls.keys.sorted() {
            let c = calls[index]!
            let input = (try? JSONValue.parse(c.arguments.isEmpty ? "{}" : c.arguments))
                ?? .object(["INVALID_JSON": .string(c.arguments)])
            blocks.append(.toolUse(ToolCall(id: c.id, name: c.name, input: input)))
        }
        let stop: StopReason = switch finishReason {
        case "tool_calls", "function_call": .toolUse
        case "length": .maxTokens
        case "content_filter": .refusal
        default: calls.isEmpty ? .endTurn : .toolUse
        }
        return [.completed(Message(role: .assistant, blocks: blocks), stop, usage)]
    }
}
