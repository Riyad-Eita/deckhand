import Foundation

/// The cheapest model that is good enough: a request is sorted into a kind of task, each kind needs a tier of model,
/// and among the user's models the cheapest of a high enough tier answers. Models on the user's own server cost
/// nothing per token, so they win whenever they're big enough.
public enum ModelRouter {
    /// The model id plain chats store for "pick for me".
    public static let auto = "auto"

    public enum TaskKind: String, Sendable, CaseIterable {
        case quick, writing, code, reasoning

        public var title: String {
            switch self {
            case .quick: String(localized: "Quick question")
            case .writing: String(localized: "Writing or summary")
            case .code: String(localized: "Code")
            case .reasoning: String(localized: "Thinking it through")
            }
        }
    }

    public enum Tier: Int, Sendable, Comparable, CaseIterable {
        case small, medium, large
        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Candidate: Sendable, Hashable, Identifiable {
        public var provider: ProviderKind
        public var model: String
        public var tier: Tier
        /// nil when the price isn't known (it then counts as expensive).
        public var price: ModelPrice?
        public var id: String { provider.rawValue + "/" + model }
        public init(provider: ProviderKind, model: String, tier: Tier? = nil, price: ModelPrice? = nil) {
            self.provider = provider; self.model = model
            self.tier = tier ?? ModelRouter.tier(of: model)
            self.price = price
        }
    }

    // MARK: - What kind of task

    public static func classify(_ text: String, images: Int = 0) -> TaskKind {
        let t = text.lowercased()
        let words = t.split { $0.isWhitespace || $0.isPunctuation }.map(String.init)
        func has(_ list: [String]) -> Bool { list.contains { k in k.contains(" ") ? t.contains(k) : words.contains(k) } }

        let codeMarks = text.contains("```") || text.contains("    at ") || text.contains("Traceback") || text.contains("=>")
            || text.range(of: #"\b\w+\.(swift|py|js|ts|go|rs|java|rb|php|sh|sql|yml|yaml|json|tsx|c|cpp)\b"#, options: .regularExpression) != nil
            || text.range(of: #"[{};]\s*\n"#, options: .regularExpression) != nil
        let codeWords = has(["code", "function", "bug", "compile", "regex", "script", "bash", "sql", "query", "stack trace", "exception",
                             "refactor", "unit test", "api", "class", "error", "nginx", "docker", "kubernetes", "git", "swift", "python",
                             "javascript", "typescript", "dockerfile", "cron", "yaml"])
        let reasonWords = has(["why", "plan", "design", "architecture", "trade-off", "tradeoff", "compare", "pros and cons", "should i",
                               "strategy", "prove", "step by step", "debug", "root cause", "analyze", "analyse", "evaluate", "decide", "migrate"])
        let writeWords = has(["summarize", "summarise", "summary", "tl;dr", "rewrite", "translate", "email", "letter", "draft", "polish",
                              "shorten", "proofread", "post", "announcement", "describe", "explain like"])

        if writeWords && !codeMarks { return .writing }
        if codeMarks && reasonWords { return .reasoning }
        if codeMarks || codeWords { return text.count > 1_500 || reasonWords ? .reasoning : .code }
        if reasonWords && text.count > 120 { return .reasoning }
        if text.count > 2_000 { return .writing }
        if images > 0 { return .writing }
        return .quick
    }

    /// The tier a task needs. Long inputs need more than their kind alone suggests.
    public static func needed(for kind: TaskKind, length: Int = 0) -> Tier {
        switch kind {
        case .quick: length > 4_000 ? .medium : .small
        case .writing: length > 20_000 ? .medium : .small
        case .code: .medium
        case .reasoning: .large
        }
    }

    /// A model's tier from its name: Haiku/mini/small open models are small, Opus/Fable/big open models large.
    public static func tier(of model: String) -> Tier {
        let m = model.lowercased()
        if let b = parameterBillions(m) { return b <= 4 ? .small : b <= 14 ? .medium : .large }
        if ["haiku", "mini", "nano", "flash-lite", "flash", "small", "tiny"].contains(where: m.contains) { return .small }
        if ["opus", "fable", "mythos", "pro", "large", "ultra"].contains(where: m.contains) { return .large }
        if m.hasPrefix("gpt-5") && !m.contains("mini") { return .large }
        return .medium
    }

    /// "qwen3:0.6b", "llama3.1:70b", "mistral-7b-instruct" → parameter count in billions.
    static func parameterBillions(_ m: String) -> Double? {
        guard let r = m.range(of: #"(\d+(\.\d+)?)b\b"#, options: .regularExpression) else { return nil }
        return Double(m[r].dropLast())
    }

    // MARK: - Which model

    /// The cheapest candidate of at least the needed tier; if none is big enough, the biggest there is.
    public static func pick(for kind: TaskKind, length: Int = 0, among candidates: [Candidate]) -> Candidate? {
        let need = needed(for: kind, length: length)
        let fitting = candidates.filter { $0.tier >= need }
        func cost(_ c: Candidate) -> Double { c.price.map { $0.input + $0.output * 4 } ?? .greatestFiniteMagnitude }
        if let best = fitting.min(by: { (cost($0), $0.tier.rawValue) < (cost($1), $1.tier.rawValue) }) { return best }
        return candidates.max { ($0.tier.rawValue, -cost($0)) < ($1.tier.rawValue, -cost($1)) }
    }
}

/// Prices in US dollars per million tokens.
public struct ModelPrice: Sendable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double

    public init(input: Double, output: Double, cacheRead: Double? = nil) {
        self.input = input; self.output = output; self.cacheRead = cacheRead ?? input / 10
    }

    public static let free = ModelPrice(input: 0, output: 0, cacheRead: 0)

    /// Anthropic's list prices (as of November 2026). OpenRouter ids ("anthropic/claude-…") map to the same model.
    /// Other providers' prices aren't listed here; those models show tokens without a price.
    public static func known(_ model: String) -> ModelPrice? {
        let id = model.split(separator: "/").last.map(String.init) ?? model
        switch id {
        case "claude-fable-5-2", "claude-mythos-5-2": return ModelPrice(input: 8, output: 40, cacheRead: 0.20)
        case "claude-opus-5-5": return ModelPrice(input: 4, output: 20, cacheRead: 0.20)
        case "claude-sonnet-5-5": return ModelPrice(input: 2, output: 10, cacheRead: 0.10)
        case "claude-haiku-5-5": return ModelPrice(input: 0.10, output: 0.50)
        default: return nil
        }
    }

    public func cost(_ u: Usage) -> Double {
        (Double(u.inputTokens) * input + Double(u.cacheReadTokens) * cacheRead + Double(u.outputTokens) * output) / 1_000_000
    }

    /// "$0.0042", "<$0.0001", "free".
    public static func format(_ dollars: Double) -> String {
        if dollars == 0 { return String(localized: "free") }
        if dollars < 0.0001 { return "<$0.0001" }
        if dollars < 0.01 { return String(format: "$%.4f", dollars) }
        return String(format: "$%.2f", dollars)
    }
}
