import Foundation

public enum ProviderKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case anthropic
    case openAI
    case openRouter
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic (Claude)"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .custom: "Custom (OpenAI-compatible)"
        }
    }

    public var defaultBaseURL: URL {
        switch self {
        case .anthropic: URL(string: "https://api.anthropic.com")!
        case .openAI: URL(string: "https://api.openai.com/v1")!
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")!
        case .custom: URL(string: "http://localhost:11434/v1")!
        }
    }

    /// Suggested models, best first. Users can type any model id.
    public var suggestedModels: [String] {
        switch self {
        case .anthropic: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-haiku-5-5"]
        case .openAI: ["gpt-5.1", "gpt-5.1-mini"]
        case .openRouter: ["anthropic/claude-opus-5-5", "openai/gpt-5.1"]
        case .custom: []
        }
    }
}

public struct ProviderConfig: Sendable, Hashable, Codable {
    public var kind: ProviderKind
    public var baseURL: URL
    public var model: String
    public var apiKey: String
    /// Reasoning effort where the provider supports it ("low" … "max").
    public var effort: String?

    public init(kind: ProviderKind, baseURL: URL? = nil, model: String, apiKey: String, effort: String? = nil) {
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.model = model
        self.apiKey = apiKey
        self.effort = effort
    }
}

public struct ChatRequest: Sendable {
    public var system: String
    public var messages: [Message]
    public var tools: [ToolSpec]
    public var maxTokens: Int

    public init(system: String, messages: [Message], tools: [ToolSpec], maxTokens: Int = 64_000) {
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
    }
}

public enum ProviderEvent: Sendable, Hashable {
    case textDelta(String)
    case thinkingDelta(String)
    case toolCallStarted(id: String, name: String)
    case toolInputDelta(id: String, fragment: String)
    /// The finished assistant message. Always the last event of a successful stream.
    case completed(Message, StopReason, Usage)
}

public enum LLMError: Error, Sendable, LocalizedError, Equatable {
    case http(status: Int, body: String)
    case badStream(String)
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            let detail = (try? JSONValue.parse(body))?["error"]?["message"]?.stringValue ?? body
            switch status {
            case 401, 403: return String(localized: "The provider rejected the API key (\(status)). \(detail)")
            case 429: return String(localized: "Rate limited by the provider. \(detail)")
            default: return String(localized: "Provider error \(status): \(detail)")
            }
        case .badStream(let s): return String(localized: "Unexpected response from the provider: \(s)")
        case .missingAPIKey: return String(localized: "Add an API key in Settings first.")
        }
    }
}

public protocol LLMProvider: Sendable {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ProviderEvent, Error>
}

public enum Providers {
    public static func make(_ config: ProviderConfig, session: URLSession = .shared) -> any LLMProvider {
        switch config.kind {
        case .anthropic: AnthropicProvider(config: config, session: session)
        case .openAI, .openRouter, .custom: OpenAIChatProvider(config: config, session: session)
        }
    }
}

/// Runs a decoder over an SSE stream and forwards its events.
func decodeStream<D: StreamDecoder>(
    _ events: AsyncThrowingStream<SSEParser.Event, Error>, decoder: D
) -> AsyncThrowingStream<ProviderEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            var decoder = decoder
            do {
                for try await event in events {
                    for out in try decoder.consume(event) { continuation.yield(out) }
                    if decoder.isFinished { break }
                }
                for out in try decoder.finish() { continuation.yield(out) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

protocol StreamDecoder: Sendable {
    var isFinished: Bool { get }
    mutating func consume(_ event: SSEParser.Event) throws -> [ProviderEvent]
    mutating func finish() throws -> [ProviderEvent]
}
