import DeckhandCore
import Foundation
import Observation

/// Model provider choice and agent behaviour. Keys live in the Keychain, the rest in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var providerKind: ProviderKind {
        didSet { defaults.set(providerKind.rawValue, forKey: "provider.kind"); loadProviderFields() }
    }
    var model: String { didSet { defaults.set(model, forKey: "provider.\(providerKind.rawValue).model") } }
    var baseURL: String { didSet { defaults.set(baseURL, forKey: "provider.\(providerKind.rawValue).baseURL") } }
    var effort: String { didSet { defaults.set(effort, forKey: "provider.effort") } }
    var approvalPolicy: ApprovalPolicy { didSet { defaults.set(approvalPolicy.rawValue, forKey: "agent.policy") } }
    var apiKey: String { didSet { Keychain.set(apiKey, for: "apikey.\(providerKind.rawValue)") } }
    /// What Codex / Claude Code may do on the server in headless runs.
    var cliAccess: CLIAccess { didSet { defaults.set(cliAccess.rawValue, forKey: "cli.access") } }
    /// Terminal opens inside tmux/screen so it survives disconnects.
    var keepTerminalSessions: Bool { didSet { defaults.set(keepTerminalSessions, forKey: "terminal.keep") } }
    /// ntfy topic URL the server pushes to when a task ends (empty: off).
    var ntfyTopicURL: String { didSet { defaults.set(ntfyTopicURL, forKey: "notify.ntfy") } }
    /// Tokens, keys and passwords: masked in the chat, replaced before tool output goes to your model.
    var hideSecrets: Bool { didSet { defaults.set(hideSecrets, forKey: "agent.hideSecrets") } }

    private init() {
        let kind = ProviderKind(rawValue: defaults.string(forKey: "provider.kind") ?? "") ?? .anthropic
        providerKind = kind
        model = ""
        baseURL = ""
        apiKey = ""
        effort = defaults.string(forKey: "provider.effort") ?? "high"
        approvalPolicy = ApprovalPolicy(rawValue: defaults.string(forKey: "agent.policy") ?? "") ?? .autoRead
        cliAccess = CLIAccess(rawValue: defaults.string(forKey: "cli.access") ?? "") ?? .edit
        keepTerminalSessions = defaults.object(forKey: "terminal.keep") as? Bool ?? true
        ntfyTopicURL = defaults.string(forKey: "notify.ntfy") ?? ""
        hideSecrets = defaults.object(forKey: "agent.hideSecrets") as? Bool ?? true
        loadProviderFields()
    }

    private func loadProviderFields() {
        let k = providerKind.rawValue
        model = defaults.string(forKey: "provider.\(k).model") ?? providerKind.suggestedModels.first ?? ""
        baseURL = defaults.string(forKey: "provider.\(k).baseURL") ?? providerKind.defaultBaseURL.absoluteString
        apiKey = Keychain.get("apikey.\(k)") ?? ""
    }

    var isConfigured: Bool {
        !model.isEmpty && (!apiKey.isEmpty || providerKind == .custom)
    }

    var providerConfig: ProviderConfig {
        ProviderConfig(
            kind: providerKind,
            baseURL: URL(string: baseURL) ?? providerKind.defaultBaseURL,
            model: model,
            apiKey: apiKey,
            effort: effort.isEmpty ? nil : effort)
    }
}
