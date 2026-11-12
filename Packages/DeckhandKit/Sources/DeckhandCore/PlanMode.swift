import Foundation

/// "Plan first": the agent looks around without changing anything and answers with a checklist; the user runs it,
/// adjusts it or drops it. Works for every engine — the turn runs read-only (own key: no write tools and every
/// command waits for approval; Claude Code: plan mode; Codex: read-only sandbox).
public enum PlanMode {
    static let instructions = """
    [Plan first] Don't change anything yet. Look around read-only as much as you need, then answer with a short \
    plan: one sentence on the approach, then the steps in a fenced block tagged plan, one step per line, like
    ```plan
    - Back up /etc/nginx/sites-available/shop
    - Change the upstream port to 8081
    - Test with nginx -t, then reload nginx
    ```
    Steps are concrete actions on this server, in order, at most 12. Mention risks after the block if there are any.
    """

    /// The message sent for a plan turn: the user's request plus the plan instructions.
    public static func wrap(_ prompt: String) -> String { prompt + "\n\n" + instructions }

    /// The user's own words without the plan instructions (for showing the message in the chat).
    public static func unwrap(_ text: String) -> String {
        guard let r = text.range(of: "\n\n[Plan first]") else { return text }
        return String(text[..<r.lowerBound])
    }

    public static func isPlanRequest(_ text: String) -> Bool { text.contains("\n\n[Plan first]") }

    /// The steps of the last ```plan block in a reply (bullets, numbers or checkboxes stripped). Nil without a block.
    public static func steps(in reply: String) -> [String]? {
        guard let open = reply.range(of: "```plan", options: .backwards) else { return nil }
        let rest = reply[open.upperBound...]
        let body = rest.range(of: "```").map { rest[..<$0.lowerBound] } ?? rest
        let steps = body.split(separator: "\n").map { line -> String in
            var s = line.trimmingCharacters(in: .whitespaces)
            for p in ["- [ ] ", "- [x] ", "* [ ] ", "- ", "* ", "• "] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)); break }
            if let r = s.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) { s.removeSubrange(r) }
            return s.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return steps.isEmpty ? nil : Array(steps.prefix(20))
    }

    /// The reply without the plan block (the approach and risks stay readable around the checklist card).
    public static func strippingPlan(_ reply: String) -> String {
        guard let open = reply.range(of: "```plan", options: .backwards) else { return reply }
        let rest = reply[open.upperBound...]
        let end = rest.range(of: "```").map(\.upperBound) ?? reply.endIndex
        return (String(reply[..<open.lowerBound]) + String(reply[end...])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The reply's text before and after the plan block.
    public static func around(_ reply: String) -> (before: String, after: String) {
        guard let open = reply.range(of: "```plan", options: .backwards) else { return (reply, "") }
        let rest = reply[open.upperBound...]
        let end = rest.range(of: "```").map(\.upperBound) ?? reply.endIndex
        return (String(reply[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                String(reply[end...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The message that carries out the (possibly trimmed) plan.
    public static func runPrompt(_ steps: [String]) -> String {
        "Go ahead with the plan:\n" + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            + "\nVerify each step, and stop and tell me if something doesn't go as planned."
    }

    /// Tools for a plan turn with your own key: everything except writing and editing files.
    public static func tools(_ all: [any AgentTool]) -> [any AgentTool] {
        all.filter { (tool: any AgentTool) in !["write_file", "edit_file"].contains(tool.spec.name) }
    }
}
