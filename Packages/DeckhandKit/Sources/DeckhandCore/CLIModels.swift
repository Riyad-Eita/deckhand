import Foundation

/// Model and effort for one Claude Code / Codex turn. nil = what the CLI's own config says.
public struct CLIOptions: Sendable, Hashable {
    public var model: String?
    public var effort: String?
    /// Spending cap for one Claude Code run (house rule). Codex runs on a subscription and has no such cap.
    public var maxBudgetUSD: Double?
    public init(model: String? = nil, effort: String? = nil, maxBudgetUSD: Double? = nil) {
        self.model = model.flatMap { $0.isEmpty ? nil : $0 }
        self.effort = effort.flatMap { $0.isEmpty ? nil : $0 }
        self.maxBudgetUSD = maxBudgetUSD.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// A model a server CLI offers.
public struct CLIModel: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var summary: String
    public var efforts: [String]
    public var defaultEffort: String?
    public init(id: String, name: String, summary: String = "", efforts: [String], defaultEffort: String? = nil) {
        self.id = id; self.name = name; self.summary = summary; self.efforts = efforts; self.defaultEffort = defaultEffort
    }
}

public enum CLIModels {
    /// Codex lists its models (with effort levels) as JSON.
    public static let codexCommand = "PATH=\"$HOME/.local/bin:$PATH\" codex debug models 2>/dev/null"

    /// Visible models in Codex's own order.
    public static func parseCodex(_ output: String) -> [CLIModel] {
        guard let start = output.firstIndex(of: "{"),
              let data = String(output[start...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models
            .filter { ($0["visibility"] as? String ?? "list") == "list" }
            .sorted { ($0["priority"] as? Int ?? 999) < ($1["priority"] as? Int ?? 999) }
            .compactMap { m in
                guard let slug = m["slug"] as? String else { return nil }
                let efforts = (m["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
                return CLIModel(
                    id: slug, name: m["display_name"] as? String ?? slug,
                    summary: m["description"] as? String ?? "", efforts: efforts,
                    defaultEffort: m["default_reasoning_level"] as? String)
            }
    }

    /// Claude Code takes aliases for the latest models (`claude --help`).
    public static let claude: [CLIModel] = [
        CLIModel(id: "fable", name: "Fable", efforts: claudeEfforts),
        CLIModel(id: "opus", name: "Opus", efforts: claudeEfforts),
        CLIModel(id: "sonnet", name: "Sonnet", efforts: claudeEfforts),
    ]
    public static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]

    /// The flags for one CLI.
    public static func flags(_ cli: ServerCLI, _ options: CLIOptions) -> String {
        var out = ""
        switch cli {
        case .codex:
            if let m = options.model { out += " -m \(ShellQuote.quote(m))" }
            if let e = options.effort { out += " -c \(ShellQuote.quote("model_reasoning_effort=\"\(e)\""))" }
        case .claudeCode:
            if let m = options.model { out += " --model \(ShellQuote.quote(m))" }
            if let e = options.effort { out += " --effort \(ShellQuote.quote(e))" }
            if let b = options.maxBudgetUSD { out += " --max-budget-usd \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), b))" }
        }
        return out
    }
}
