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
    /// Default model / effort per server CLI ("" = the CLI's own config on the server).
    var codexModel: String { didSet { defaults.set(codexModel, forKey: "cli.codex.model") } }
    var codexEffort: String { didSet { defaults.set(codexEffort, forKey: "cli.codex.effort") } }
    var claudeModel: String { didSet { defaults.set(claudeModel, forKey: "cli.claude.model") } }
    var claudeEffort: String { didSet { defaults.set(claudeEffort, forKey: "cli.claude.effort") } }
    /// Codex's model list as last read from a server, for the Settings picker.
    var codexModels: [CLIModel] {
        didSet { defaults.set(try? JSONEncoder().encode(codexModels), forKey: "cli.codex.models") }
    }
    /// Face ID / passcode before the app shows anything.
    var appLock: Bool { didSet { defaults.set(appLock, forKey: "lock.enabled") } }
    /// Seconds in the background before the lock comes back (0 = every time).
    var lockDelay: TimeInterval { didSet { defaults.set(lockDelay, forKey: "lock.delay") } }

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
        codexModel = defaults.string(forKey: "cli.codex.model") ?? ""
        codexEffort = defaults.string(forKey: "cli.codex.effort") ?? ""
        claudeModel = defaults.string(forKey: "cli.claude.model") ?? ""
        claudeEffort = defaults.string(forKey: "cli.claude.effort") ?? ""
        codexModels = (defaults.data(forKey: "cli.codex.models")).flatMap { try? JSONDecoder().decode([CLIModel].self, from: $0) } ?? []
        appLock = defaults.bool(forKey: "lock.enabled")
        lockDelay = defaults.object(forKey: "lock.delay") as? Double ?? 60
        loadProviderFields()
    }

    private func loadProviderFields() {
        let k = providerKind.rawValue
        model = defaults.string(forKey: "provider.\(k).model") ?? providerKind.suggestedModels.first ?? ""
        baseURL = defaults.string(forKey: "provider.\(k).baseURL") ?? providerKind.defaultBaseURL.absoluteString
        apiKey = Keychain.get("apikey.\(k)") ?? ""
    }

    /// What a task runs with: its own choice, else the default here, else the CLI's config.
    func cliOptions(for cli: ServerCLI, thread: ChatThread) -> CLIOptions {
        switch cli {
        case .codex: CLIOptions(model: thread.cliModel ?? codexModel, effort: thread.cliEffort ?? codexEffort)
        case .claudeCode: CLIOptions(model: thread.cliModel ?? claudeModel, effort: thread.cliEffort ?? claudeEffort)
        }
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
