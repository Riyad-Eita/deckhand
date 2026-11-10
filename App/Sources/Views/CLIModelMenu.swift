import DeckhandCore
import SwiftUI

/// Model and effort for a Claude Code / Codex task, in the chat header. Applies from the next message on.
struct CLIModelMenu: View {
    @Bindable var thread: ChatThread
    let server: Server
    let cli: ServerCLI

    @Environment(Connections.self) private var connections
    @Environment(AppSettings.self) private var settings
    @State private var codexModels: [CLIModel] = AppSettings.shared.codexModels

    private var models: [CLIModel] { cli == .codex ? codexModels : CLIModels.claude }

    var body: some View {
        Menu {
            Picker(selection: $thread.cliModel) {
                Text(defaultLabel(model: true)).tag(String?.none)
                ForEach(models) { m in
                    Text(m.name).tag(String?.some(m.id))
                }
            } label: {
                Label("Model", systemImage: "cpu")
            }
            .pickerStyle(.menu)
            Picker(selection: $thread.cliEffort) {
                Text(defaultLabel(model: false)).tag(String?.none)
                ForEach(efforts, id: \.self) { e in
                    Text(CLIModelMenu.effortName(e)).tag(String?.some(e))
                }
            } label: {
                Label("Effort", systemImage: "gauge.with.dots.needle.67percent")
            }
            .pickerStyle(.menu)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .accessibilityLabel("Model and Effort")
        .accessibilityIdentifier("chat.modelMenu")
        .task { if cli == .codex { await loadCodexModels() } }
    }

    private var efforts: [String] {
        let chosen = thread.cliModel ?? (cli == .codex ? settings.codexModel : settings.claudeModel)
        if let m = models.first(where: { $0.id == chosen }), !m.efforts.isEmpty { return m.efforts }
        let all = cli == .codex ? codexModels.flatMap(\.efforts) : CLIModels.claudeEfforts
        var seen = Set<String>()
        return all.filter { seen.insert($0).inserted }
    }

    private func defaultLabel(model: Bool) -> String {
        let value = switch (cli, model) {
        case (.codex, true): settings.codexModel
        case (.codex, false): settings.codexEffort
        case (.claudeCode, true): settings.claudeModel
        case (.claudeCode, false): settings.claudeEffort
        }
        guard !value.isEmpty else { return String(localized: "Default (server setting)") }
        let name = model ? (models.first { $0.id == value }?.name ?? value) : CLIModelMenu.effortName(value)
        return String(localized: "Default (\(name))")
    }

    private func loadCodexModels() async {
        guard let conn = try? await connections.connection(for: server),
              let r = try? await conn.run(CLIModels.codexCommand, timeout: .seconds(30)) else { return }
        let list = CLIModels.parseCodex(r.stdout)
        guard !list.isEmpty else { return }
        codexModels = list
        settings.codexModels = list
    }

    static func effortName(_ effort: String) -> String {
        switch effort {
        case "low": String(localized: "Low")
        case "medium": String(localized: "Medium")
        case "high": String(localized: "High")
        case "xhigh": String(localized: "Extra high")
        case "max": String(localized: "Max")
        case "ultra": String(localized: "Ultra")
        default: effort
        }
    }

    /// "Opus · High" for the header, or nil when everything is on default.
    static func summary(cli: ServerCLI, thread: ChatThread, settings: AppSettings) -> String? {
        let o = settings.cliOptions(for: cli, thread: thread)
        let models = cli == .codex ? settings.codexModels : CLIModels.claude
        let name = o.model.map { id in models.first { $0.id == id }?.name ?? id }
        let parts = [name, o.effort.map(effortName)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Default model and effort for each server CLI.
struct CLIDefaultsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Picker("Claude Code model", selection: $settings.claudeModel) {
            Text("Server setting").tag("")
            ForEach(CLIModels.claude) { Text($0.name).tag($0.id) }
        }
        Picker("Claude Code effort", selection: $settings.claudeEffort) {
            Text("Server setting").tag("")
            ForEach(CLIModels.claudeEfforts, id: \.self) { Text(CLIModelMenu.effortName($0)).tag($0) }
        }
        Picker("Codex model", selection: $settings.codexModel) {
            Text("Server setting").tag("")
            ForEach(settings.codexModels) { Text($0.name).tag($0.id) }
            if !settings.codexModel.isEmpty && !settings.codexModels.contains(where: { $0.id == settings.codexModel }) {
                Text(settings.codexModel).tag(settings.codexModel)
            }
        }
        Picker("Codex effort", selection: $settings.codexEffort) {
            Text("Server setting").tag("")
            ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { Text(CLIModelMenu.effortName($0)).tag($0) }
        }
    }
}
