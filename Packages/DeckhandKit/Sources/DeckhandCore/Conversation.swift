import Foundation

public enum Role: String, Sendable, Codable, Hashable {
    case user
    case assistant
}

/// One piece of a message. Provider-specific blocks the app does not understand are kept as `opaque`
/// so they can be sent back unchanged on the next request.
public enum ContentBlock: Sendable, Hashable, Codable {
    case text(String)
    case thinking(text: String, signature: String?)
    case toolUse(ToolCall)
    case toolResult(ToolResult)
    case opaque(provider: String, value: JSONValue)
    /// A picture the user attached (JPEG or PNG), sent to models that can see.
    case image(mediaType: String, data: Data)
}

public struct ToolCall: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var input: JSONValue
    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }
}

public struct ToolResult: Sendable, Hashable, Codable {
    public var toolUseID: String
    public var content: String
    public var isError: Bool
    public init(toolUseID: String, content: String, isError: Bool = false) {
        self.toolUseID = toolUseID
        self.content = content
        self.isError = isError
    }
}

public struct Message: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var role: Role
    public var blocks: [ContentBlock]
    /// When the message was made (nil for messages stored before times were kept).
    public var date: Date?

    public init(id: UUID = UUID(), role: Role, blocks: [ContentBlock], date: Date? = Date()) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.date = date
    }

    public static func user(_ text: String) -> Message { Message(role: .user, blocks: [.text(text)]) }

    public var text: String {
        blocks.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }

    public var toolCalls: [ToolCall] {
        blocks.compactMap { if case .toolUse(let c) = $0 { c } else { nil } }
    }
}

public struct ToolSpec: Sendable, Hashable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum StopReason: String, Sendable, Hashable, Codable {
    case endTurn
    case toolUse
    case maxTokens
    case refusal
    case pauseTurn
    case cancelled
    case other
}

public struct Usage: Sendable, Hashable, Codable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
    }
}
