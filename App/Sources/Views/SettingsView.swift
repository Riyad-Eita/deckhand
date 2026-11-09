import DeckhandCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $settings.providerKind) {
                        ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    SecureField(settings.providerKind == .custom ? "API key (optional)" : "API key", text: $settings.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.mono)
                    if !settings.providerKind.suggestedModels.isEmpty {
                        Picker("Model", selection: $settings.model) {
                            ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    TextField("Model id", text: $settings.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.mono)
                } header: {
                    Text("Model")
                } footer: {
                    Text(keyHint)
                }

                if settings.providerKind == .custom || settings.providerKind == .openRouter {
                    Section("Endpoint") {
                        TextField("Base URL", text: $settings.baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(Theme.mono)
                    }
                }

                Section {
                    Picker("Effort", selection: $settings.effort) {
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                        Text("Max").tag("max")
                    }
                    Picker("Approvals", selection: $settings.approvalPolicy) {
                        ForEach(ApprovalPolicy.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Agent")
                } footer: {
                    Text("“Ask before changes” lets the agent read files and list folders on its own and waits for you before it runs commands or edits files.")
                }

                Section {
                    Picker("Access", selection: $settings.cliAccess) {
                        ForEach(CLIAccess.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Codex & Claude Code on the server")
                } footer: {
                    Text("Server runs can't stop to ask you. “Edit files” lets them change files in the task's folder; “Full access” also runs any command.")
                }

                Section {
                    LabeledContent("Keys", value: "Stored in this iPhone's Keychain")
                    LabeledContent("Requests", value: "Go straight to your provider")
                } header: {
                    Text("Privacy")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var modelChoices: [String] {
        let suggested = settings.providerKind.suggestedModels
        return suggested.contains(settings.model) || settings.model.isEmpty ? suggested : suggested + [settings.model]
    }

    private var keyHint: String {
        switch settings.providerKind {
        case .anthropic: "Create a key at console.anthropic.com → API Keys."
        case .openAI: "Create a key at platform.openai.com → API keys."
        case .openRouter: "Create a key at openrouter.ai → Keys. One key, many models."
        case .custom: "Any OpenAI-compatible server, e.g. Ollama on your own machine."
        }
    }
}
