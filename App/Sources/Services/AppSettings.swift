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
    /// Keep the server list (no secrets) in iCloud, on every device of this Apple Account.
    var syncServers: Bool { didSet { defaults.set(syncServers, forKey: "sync.servers"); ServerSyncService.shared.settingChanged() } }
    /// Also server passwords and keys, through iCloud Keychain (end-to-end encrypted); not with Face ID protection.
    var syncKeys: Bool { didSet { defaults.set(syncKeys, forKey: "sync.keys"); ServerSyncService.shared.keySettingChanged() } }
    /// Terminal color scheme (`TerminalTheme.id`) and font size, changed by pinching.
    var terminalTheme: String { didSet { defaults.set(terminalTheme, forKey: "terminal.theme") } }
    var terminalFontSize: Double { didSet { defaults.set(terminalFontSize, forKey: "terminal.fontSize") } }
    /// ntfy topic URL the server pushes to when a task ends (empty: off).
    var ntfyTopicURL: String { didSet { defaults.set(ntfyTopicURL, forKey: "notify.ntfy") } }
    /// Tokens, keys and passwords: masked in the chat, replaced before tool output goes to your model.
    var hideSecrets: Bool { didSet { defaults.set(hideSecrets, forKey: "agent.hideSecrets") } }
    /// Spending limits for the own key, in US dollars (0 = no limit).
    var taskLimitUSD: Double { didSet { defaults.set(taskLimitUSD, forKey: "spend.limit.task") } }
    var dayLimitUSD: Double { didSet { defaults.set(dayLimitUSD, forKey: "spend.limit.day") } }
    var spendLimits: Spend.Limits { Spend.Limits(perTaskUSD: taskLimitUSD, perDayUSD: dayLimitUSD) }
    /// What the own key cost today (all chats and tasks on this device).
    var spentToday: Double { defaults.double(forKey: "spend.day.\(Spend.dayKey())") }
    func recordSpend(_ dollars: Double) {
        guard dollars > 0 else { return }
        let key = "spend.day.\(Spend.dayKey())"
        defaults.set(defaults.double(forKey: key) + dollars, forKey: key)
    }
    /// The price of a model: the router's list first (it knows local models are free), then the known prices,
    /// then what the provider's live list said (OpenRouter sends prices).
    func price(for model: String) -> ModelPrice? {
        routerCandidates.first { $0.model == model }?.price ?? ModelPrice.known(model)
            ?? liveModels.values.lazy.compactMap { $0.first { $0.id == model }?.price?.price }.first
    }

    /// The provider's current models (`/models`), kept per provider until the next refresh.
    private(set) var liveModels: [ProviderKind: [ModelList.Model]] = [:]
    private(set) var modelListError: [ProviderKind: String] = [:]

    func modelChoices(for kind: ProviderKind) -> [(id: String, recommended: Bool)] {
        ModelList.choices(live: liveModels[kind], kind: kind)
    }

    /// Loads the provider's model list (needs its key, except for a local server). Keeps the last good list.
    func refreshModels(_ kind: ProviderKind) async {
        let config = providerConfig(kind: kind, model: nil)
        guard !config.apiKey.isEmpty || kind == .custom || kind == .openRouter else { return }
        do {
            let (data, response) = try await URLSession.shared.data(for: ModelList.request(config))
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                _ = try ModelList.parse(data, kind: kind)   // throws the provider's own message when it sent one
                throw LLMError.badStream(String(localized: "The provider answered \(http.statusCode)."))
            }
            let models = try ModelList.parse(data, kind: kind)
            guard !models.isEmpty else { return }
            liveModels[kind] = models
            modelListError[kind] = nil
            defaults.set(try? JSONEncoder().encode(models), forKey: "provider.\(kind.rawValue).liveModels")
        } catch {
            modelListError[kind] = error.localizedDescription
        }
    }
    /// Default model / effort per server CLI ("" = the CLI's own config on the server).
    var codexModel: String { didSet { defaults.set(codexModel, forKey: "cli.codex.model") } }
    var codexEffort: String { didSet { defaults.set(codexEffort, forKey: "cli.codex.effort") } }
    var claudeModel: String { didSet { defaults.set(claudeModel, forKey: "cli.claude.model") } }
    var claudeEffort: String { didSet { defaults.set(claudeEffort, forKey: "cli.claude.effort") } }
    /// Codex's model list as last read from a server, for the Settings picker.
    var codexModels: [CLIModel] {
        didSet { defaults.set(try? JSONEncoder().encode(codexModels), forKey: "cli.codex.models") }
    }
    /// Plain chats without an API key: Claude Code or Codex on one of the user's servers, with their own plan
    /// ("" = off). `planChatServer` is the server's id.
    var planChatCLI: String { didSet { defaults.set(planChatCLI, forKey: "chat.plan.cli") } }
    var planChatServer: String { didSet { defaults.set(planChatServer, forKey: "chat.plan.server") } }
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
        // Server runs can't ask, so "Edit files" blocked even reading logs. Full access is the default since 1.5
        // (house rules still block what they forbid); the old default moves up once.
        if defaults.string(forKey: "cli.access") == CLIAccess.edit.rawValue && !defaults.bool(forKey: "cli.access.v2") {
            defaults.set(CLIAccess.full.rawValue, forKey: "cli.access")
        }
        defaults.set(true, forKey: "cli.access.v2")
        cliAccess = CLIAccess(rawValue: defaults.string(forKey: "cli.access") ?? "") ?? .full
        keepTerminalSessions = defaults.object(forKey: "terminal.keep") as? Bool ?? true
        syncServers = defaults.bool(forKey: "sync.servers")
        syncKeys = defaults.bool(forKey: "sync.keys")
        terminalTheme = defaults.string(forKey: "terminal.theme") ?? TerminalTheme.default.id
        terminalFontSize = defaults.object(forKey: "terminal.fontSize") as? Double ?? TerminalFont.default
        ntfyTopicURL = defaults.string(forKey: "notify.ntfy") ?? ""
        hideSecrets = defaults.object(forKey: "agent.hideSecrets") as? Bool ?? true
        taskLimitUSD = defaults.double(forKey: "spend.limit.task")
        dayLimitUSD = defaults.double(forKey: "spend.limit.day")
        codexModel = defaults.string(forKey: "cli.codex.model") ?? ""
        codexEffort = defaults.string(forKey: "cli.codex.effort") ?? ""
        claudeModel = defaults.string(forKey: "cli.claude.model") ?? ""
        claudeEffort = defaults.string(forKey: "cli.claude.effort") ?? ""
        codexModels = (defaults.data(forKey: "cli.codex.models")).flatMap { try? JSONDecoder().decode([CLIModel].self, from: $0) } ?? []
        planChatCLI = defaults.string(forKey: "chat.plan.cli") ?? ""
        planChatServer = defaults.string(forKey: "chat.plan.server") ?? ""
        appLock = defaults.bool(forKey: "lock.enabled")
        lockDelay = defaults.object(forKey: "lock.delay") as? Double ?? 60
        loadProviderFields()
        for kind in ProviderKind.allCases {
            if let data = defaults.data(forKey: "provider.\(kind.rawValue).liveModels"),
               let models = try? JSONDecoder().decode([ModelList.Model].self, from: data) { liveModels[kind] = models }
        }
    }

    private func loadProviderFields() {
        let k = providerKind.rawValue
        model = defaults.string(forKey: "provider.\(k).model") ?? providerKind.suggestedModels.first ?? ""
        baseURL = defaults.string(forKey: "provider.\(k).baseURL") ?? providerKind.defaultBaseURL.absoluteString
        apiKey = Keychain.get("apikey.\(k)") ?? ""
    }

    /// What a task runs with: its own choice, else the default here, else the CLI's config.
    /// The model and effort from Settings, for runs without a chat (scheduled tasks).
    func cliOptions(for cli: ServerCLI) -> CLIOptions {
        switch cli {
        case .codex: CLIOptions(model: codexModel, effort: codexEffort)
        case .claudeCode: CLIOptions(model: claudeModel, effort: claudeEffort)
        }
    }

    func cliOptions(for cli: ServerCLI, thread: ChatThread) -> CLIOptions {
        switch cli {
        case .codex: CLIOptions(model: thread.cliModel ?? codexModel, effort: thread.cliEffort ?? codexEffort)
        case .claudeCode: CLIOptions(model: thread.cliModel ?? claudeModel, effort: thread.cliEffort ?? claudeEffort)
        }
    }

    var isConfigured: Bool {
        !model.isEmpty && (!apiKey.isEmpty || providerKind == .custom)
    }

    /// The plan route for new chats, when one is set up.
    var planChat: (cli: ServerCLI, server: UUID)? {
        guard let cli = ServerCLI(rawValue: planChatCLI), let id = UUID(uuidString: planChatServer) else { return nil }
        return (cli, id)
    }

    /// Providers a plain chat can use: those with a key (the custom one with an address).
    var chatProviders: [ProviderKind] {
        ProviderKind.allCases.filter { k in
            if k == providerKind { return isConfigured }
            if k == .custom { return defaults.string(forKey: "provider.custom.baseURL") != nil }
            return !(Keychain.get("apikey.\(k.rawValue)") ?? "").isEmpty
        }
    }

    /// Every model a chat could use, with its tier and price, for "pick for me" and comparisons. Models on the user's
    /// own server (or localhost) cost nothing per token.
    var routerCandidates: [ModelRouter.Candidate] {
        chatProviders.flatMap { kind -> [ModelRouter.Candidate] in
            let models = Array(Set(kind.suggestedModels + [defaultModel(for: kind)])).filter { !$0.isEmpty }.sorted()
            let base = defaults.string(forKey: "provider.\(kind.rawValue).baseURL") ?? ""
            let local = kind == .custom && (base.hasPrefix(ServerModelURL.scheme) || base.contains("localhost") || base.contains("127.0.0.1"))
            return models.map { ModelRouter.Candidate(provider: kind, model: $0, price: local ? .free : ModelPrice.known($0)) }
        }
    }

    /// The model chosen in Settings for a provider (or its first suggestion).
    func defaultModel(for kind: ProviderKind) -> String {
        defaults.string(forKey: "provider.\(kind.rawValue).model") ?? kind.suggestedModels.first ?? ""
    }

    /// A provider's settings with another model (plain chats switch models per chat).
    func providerConfig(kind: ProviderKind, model: String?) -> ProviderConfig {
        let k = kind.rawValue
        return ProviderConfig(
            kind: kind,
            baseURL: URL(string: defaults.string(forKey: "provider.\(k).baseURL") ?? "") ?? kind.defaultBaseURL,
            model: model ?? defaultModel(for: kind),
            apiKey: kind == providerKind ? apiKey : Keychain.get("apikey.\(k)") ?? "",
            effort: effort.isEmpty ? nil : effort)
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
