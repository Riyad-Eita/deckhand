import Foundation

/// "Explain" for any output: what it means, the likely cause and the next step — from the on-device model or the
/// user's key — plus "Fix it" as a task. Also short task titles.
public enum Explain {
    public static let instructions = """
    You explain technical output (terminal, logs, command results) to someone on their phone. In at most five \
    short sentences: what it means, the most likely cause, and the next thing to check or do. Plain words, no \
    preamble, no Markdown headings. If it looks fine, say so in one sentence.
    """

    /// The prompt for `text` (the end is kept when it is long: errors usually come last).
    public static func prompt(_ text: String, context: String? = nil, limit: Int = 6_000) -> String {
        let clean = stripANSI(text).trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = clean.count > limit ? "…\n" + String(clean.suffix(limit)) : clean
        return (context.map { "Where it comes from: \($0)\n" } ?? "") + "Output:\n" + cut
    }

    /// A task that fixes what was explained.
    public static func fixPrompt(_ text: String, explanation: String, context: String? = nil) -> String {
        let clean = String(stripANSI(text).trimmingCharacters(in: .whitespacesAndNewlines).suffix(4_000))
        return """
        Fix this problem\(context.map { " (\($0))" } ?? ""). Find the cause first, tell me what you'll change and ask before risky steps.

        Output:
        \(clean)

        A first explanation: \(explanation)
        """
    }

    public static let titleInstructions = "Write a title of at most six words for the user's request. Answer with the title only, no quotes, no period."

    /// One line, no quotes or trailing period, at most 60 characters.
    public static func cleanTitle(_ s: String) -> String {
        var t = s.split(separator: "\n").first.map(String.init) ?? ""
        t = t.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’*#"))
        if t.hasPrefix("Title:") { t = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        if t.hasSuffix(".") { t.removeLast() }
        return String(t.prefix(60))
    }

    /// Terminal text without colour and cursor escape sequences.
    public static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[ -/]*[@-~]|\x{1B}\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)|\x{1B}[()][A-Za-z0-9]|\x{1B}[=>]"#,
                               with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "")
    }

    /// The last `lines` non-empty lines.
    public static func tail(_ s: String, lines: Int = 40) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(lines).joined(separator: "\n")
    }
}

public extension LLMProvider {
    /// One call without tools; the reply's text.
    func complete(system: String, prompt: String, maxTokens: Int = 1_500) async throws -> String {
        var text = ""
        for try await event in stream(ChatRequest(system: system, messages: [.user(prompt)], tools: [], maxTokens: maxTokens)) {
            if case .completed(let m, _, _) = event { text = m.text }
        }
        return text
    }
}
