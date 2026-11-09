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

                VoiceSettingsSection()

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

private struct VoiceSettingsSection: View {
    @State private var voice = VoiceInput.shared
    @State private var confirmDelete = false

    var body: some View {
        Section {
            switch voice.state {
            case .notInstalled:
                Button { voice.install() } label: {
                    Label("Download Whisper (\(VoiceInput.approximateSize))", systemImage: "arrow.down.circle")
                }
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: fraction) {
                        Text("Downloading Whisper…")
                    } currentValueLabel: {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                    }
                    Button("Cancel", role: .cancel) { voice.cancelInstall() }.font(.footnote)
                }
            case .installed:
                LabeledContent("Whisper large-v3", value: "Installed")
                Button("Remove Model", role: .destructive) { confirmDelete = true }
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.red)
                Button("Try Again") { voice.install() }
            }
        } header: {
            Text("Voice input")
        } footer: {
            Text("Speech is turned into text on this iPhone with OpenAI's Whisper model. Once it is installed, a microphone appears next to the message field.")
        }
        .confirmationDialog("Remove the Whisper model?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { voice.remove() }
        }
    }
}
