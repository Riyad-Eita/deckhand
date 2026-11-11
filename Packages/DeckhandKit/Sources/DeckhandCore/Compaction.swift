import Foundation

/// Keeps long tasks inside the model's context: older steps become one summary, the recent ones stay as they are.
public enum Compaction {
    static let marker = "[Summary of earlier work in this task]"

    /// A rough token count (4 characters per token), tool results included.
    public static func estimate(_ messages: [Message]) -> Int {
        messages.reduce(0) { sum, m in
            sum + m.blocks.reduce(0) { s, b in
                switch b {
                case .text(let t): s + t.count / 4
                case .thinking(let t, _): s + t.count / 4
                case .toolUse(let c): s + (c.input.jsonString().count + c.name.count) / 4
                case .toolResult(let r): s + r.content.count / 4
                @unknown default: s
                }
            } + 4
        }
    }

    /// The summary as the first two messages (user, assistant), so the turns keep alternating.
    public static func prefix(_ summary: String) -> [Message] {
        [.user("\(marker)\n\(summary)"), Message(role: .assistant, blocks: [.text("Understood. I'll continue from there.")])]
    }

    static func summaryPrefixCount(_ history: [Message]) -> Int {
        history.first.map { $0.role == .user && $0.text.hasPrefix(marker) } == true ? 2 : 0
    }

    /// Where the kept part starts: an assistant message at least 6 messages from the end (so tool calls and their
    /// results stay together and the kept part can follow the summary pair). Nil when there's too little to cut.
    static func cutIndex(_ messages: [Message], prefix: Int) -> Int? {
        var i = max(prefix + 2, messages.count - 6)
        while i > prefix + 1 {
            if messages[i].role == .assistant { return i }
            i -= 1
        }
        return nil
    }

    static let instructions = """
    Summarize this part of an agent's work on a server so it can continue without it. Keep: the user's goal and \
    requests, decisions, what was changed (files, commands, services), important findings and values, errors and how \
    they were handled, and what is still open. Be concise and factual; use short bullet points.
    """

    static func transcript(_ messages: [Message]) -> String {
        messages.map { m in
            m.blocks.map { b -> String in
                switch b {
                case .text(let t): "\(m.role == .user ? "User" : "Agent"): \(t)"
                case .thinking: ""
                case .toolUse(let c): "Agent ran \(c.name): \(String(c.input.jsonString().prefix(800)))"
                case .toolResult(let r): "Result\(r.isError ? " (error)" : ""): \(String(r.content.prefix(1500)))"
                @unknown default: ""
                }
            }.filter { !$0.isEmpty }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func summarize(_ old: [Message], provider: any LLMProvider) async throws -> String {
        let request = ChatRequest(system: instructions, messages: [.user(transcript(old))], tools: [], maxTokens: 4_000)
        var text = ""
        for try await event in provider.stream(request) {
            if case .completed(let m, _, _) = event { text = m.text }
        }
        return text.isEmpty ? "(Earlier steps could not be summarized.)" : text
    }
}
