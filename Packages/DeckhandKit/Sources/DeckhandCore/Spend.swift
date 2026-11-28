import Foundation

/// What tasks with the user's own key cost, and the limits they set: per task and per day. The phone keeps the
/// ledger (no backend); prices come from `ModelPrice`, so models without a known price count tokens only.
public enum Spend {
    /// From this share of a limit on, the chat warns.
    public static let warnShare = 0.8

    public struct Limits: Sendable, Hashable, Codable {
        public var perTaskUSD: Double?
        public var perDayUSD: Double?
        public init(perTaskUSD: Double? = nil, perDayUSD: Double? = nil) {
            self.perTaskUSD = perTaskUSD.flatMap { $0 > 0 ? $0 : nil }
            self.perDayUSD = perDayUSD.flatMap { $0 > 0 ? $0 : nil }
        }
        public var isEmpty: Bool { perTaskUSD == nil && perDayUSD == nil }
    }

    public enum Verdict: Sendable, Hashable {
        case ok
        /// Close to a limit: tell the user, keep going.
        case warn(String)
        /// At or over a limit: stop before the next model call.
        case stop(String)
    }

    /// Checks what a task and today have cost against the limits. The tighter problem wins.
    public static func check(task: Double, day: Double, limits: Limits) -> Verdict {
        if let cap = limits.perTaskUSD, task >= cap {
            return .stop(String(localized: "This task reached its limit of \(ModelPrice.format(cap)) (spent \(ModelPrice.format(task))). Raise the limit in Settings to go on."))
        }
        if let cap = limits.perDayUSD, day >= cap {
            return .stop(String(localized: "Today's limit of \(ModelPrice.format(cap)) is reached (spent \(ModelPrice.format(day))). It resets at midnight, or raise it in Settings."))
        }
        if let cap = limits.perTaskUSD, task >= cap * warnShare {
            return .warn(String(localized: "This task has used \(ModelPrice.format(task)) of its \(ModelPrice.format(cap)) limit."))
        }
        if let cap = limits.perDayUSD, day >= cap * warnShare {
            return .warn(String(localized: "Today's spending is at \(ModelPrice.format(day)) of \(ModelPrice.format(cap))."))
        }
        return .ok
    }

    /// Tokens and cost of a conversation, from the usage stored on its replies.
    public struct Total: Sendable, Hashable {
        public var tokens = 0
        public var cost = 0.0
        /// Some replies came from a model without a known price: the cost is a lower bound.
        public var unpriced = false
        public init() {}
    }

    public static func total(_ messages: [Message], price: (String) -> ModelPrice? = ModelPrice.known) -> Total {
        var t = Total()
        for m in messages where m.role == .assistant {
            guard let u = m.usage else { continue }
            t.tokens += u.inputTokens + u.cacheReadTokens + u.outputTokens
            if let model = m.model, let p = price(model) { t.cost += p.cost(u) } else if u.outputTokens > 0 { t.unpriced = true }
        }
        return t
    }

    /// "12.4k tokens · $0.03" for a task.
    public static func label(_ t: Total) -> String {
        let tokens = t.tokens >= 1000 ? String(format: "%.1fk", Double(t.tokens) / 1000) : "\(t.tokens)"
        let base = String(localized: "\(tokens) tokens")
        if t.cost == 0 && t.unpriced { return base }
        return base + " · " + (t.unpriced ? "≥ " : "") + ModelPrice.format(t.cost)
    }

    /// Day key for the ledger, in the user's time zone.
    public static func dayKey(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
