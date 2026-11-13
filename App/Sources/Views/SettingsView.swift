import DeckhandCore
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $settings.providerKind) {
                        ForEach(ProviderKind.allCases) { kind in
                            Label {
                                Text(LocalizedStringKey(kind.displayName))
                            } icon: {
                                if let brand = Brand.forProvider(kind) {
                                    Image(brand.asset).renderingMode(.template)
                                } else {
                                    Image(systemName: "server.rack")
                                }
                            }
                            .tag(kind)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            BrandIcon(brand: Brand.forProvider(settings.providerKind), fallback: "server.rack", size: 26)
                            Text("Provider")
                        }
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
                        if let url = URL(string: settings.baseURL), ServerModelURL.parse(url) != nil {
                            Label(String(localized: "On \(ServerTunnels.serverName(for: url) ?? String(localized: "a removed server")), through SSH"),
                                  systemImage: "server.rack")
                                .accessibilityIdentifier("settings.serverModel")
                            Button("Use another address") { settings.baseURL = ProviderKind.custom.defaultBaseURL.absoluteString }
                        } else {
                            TextField("Base URL", text: $settings.baseURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .font(Theme.mono)
                        }
                    }
                }

                AppLockSection()

                Section {
                    Picker("Effort", selection: $settings.effort) {
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                        Text("Max").tag("max")
                    }
                    Picker("Approvals", selection: $settings.approvalPolicy) {
                        ForEach(ApprovalPolicy.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                    Toggle("Hide Secrets", isOn: $settings.hideSecrets)
                        .accessibilityIdentifier("settings.hideSecrets")
                } header: {
                    Text("Agent")
                } footer: {
                    Text("“Ask before changes” lets the agent read files and list folders on its own and waits for you before it runs commands or edits files. “Hide Secrets” masks tokens, keys and passwords in the chat (tap to show) and replaces them before command output goes to your model.")
                }

                Section {
                    Picker("Access", selection: $settings.cliAccess) {
                        ForEach(CLIAccess.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                    CLIDefaultsSection()
                } header: {
                    Text("Codex & Claude Code on the server")
                } footer: {
                    Text("Server runs can't stop to ask you. “Edit files” lets them change files in the task's folder; “Full access” also runs any command. Model and effort can also be changed per task in the chat header; “Server setting” uses the CLI's own config.")
                }

                Section {
                    NavigationLink {
                        ConnectionsView()
                    } label: {
                        HStack(spacing: 10) {
                            BrandIcon(brand: .mcp, size: 26)
                            Text("Connections")
                        }
                    }
                } footer: {
                    Text("MCP servers like GitHub, documentation or your own tools — for every agent.")
                }

                Section {
                    Toggle("Keep terminal sessions", isOn: $settings.keepTerminalSessions)
                } header: {
                    Text("Terminal")
                } footer: {
                    Text("Opens the terminal inside tmux or screen on the server, so your session keeps running when the connection drops and you can pick up where you left off.")
                }

                VoiceSettingsSection()
                NotificationSettingsSection()

                Section {
                    NavigationLink { KeysView() } label: {
                        RowLabel(title: String(localized: "SSH keys"), subtitle: String(localized: "Rotate keys, remove lost devices")) {
                            Image(systemName: "key").foregroundStyle(Theme.accent).frame(width: 26)
                        }
                    }
                    .accessibilityIdentifier("settings.keys")
                    NavigationLink { AppBackupView() } label: {
                        RowLabel(title: String(localized: "Move to a new iPhone"), subtitle: String(localized: "Encrypted backup of servers and settings")) {
                            Image(systemName: "iphone.and.arrow.forward").foregroundStyle(Theme.accent).frame(width: 26)
                        }
                    }
                    .accessibilityIdentifier("settings.appBackup")
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

/// Local notifications always; optional push straight from the server through an ntfy topic.
private struct NotificationSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Push from the server (ntfy)", isOn: Binding(
                get: { !settings.ntfyTopicURL.isEmpty },
                set: { settings.ntfyTopicURL = $0 ? TaskNotifier.newTopicURL() : "" }))
            if !settings.ntfyTopicURL.isEmpty {
                TextField("Topic URL", text: $settings.ntfyTopicURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(Theme.monoSmall)
                HStack {
                    Button("Copy topic") { UIPasteboard.general.string = settings.ntfyTopicURL }
                    Spacer()
                    Button {
                        Task {
                            testing = true
                            let ok = await TaskNotifier.testNtfy(settings.ntfyTopicURL)
                            testResult = ok ? String(localized: "Sent — check the ntfy app.") : String(localized: "Couldn't reach the topic.")
                            testing = false
                        }
                    } label: { if testing { ProgressView() } else { Text("Send a test") } }
                }
                .buttonStyle(.borderless)
                if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }
                Link("Get the ntfy app", destination: URL(string: "https://apps.apple.com/app/ntfy/id1625396347")!)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Deckhand tells you when a task is done or needs your approval. Once the app is closed, iOS only lets it check now and then — with ntfy, your server pushes the moment a task ends. Subscribe to the topic in the ntfy app; only the task's title is sent. You can use your own ntfy server.")
        }
    }
}

/// App lock: on/off (needs one successful Face ID / passcode check) and how long the app may stay in the background.
private struct AppLockSection: View {
    @Environment(AppSettings.self) private var settings
    @Query private var servers: [Server]
    @State private var method = AppLock.shared.method
    @State private var keysProtected = KeyProtection.shared.enabled
    @State private var switching = false

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle(isOn: Binding(get: { settings.appLock }, set: { on in
                if !on { settings.appLock = false; return }
                Task { if await AppLock.shared.confirmEnable() { settings.appLock = true } }
            })) {
                Label(String(localized: "Lock with \(method ?? "Face ID")"), systemImage: method == "Touch ID" ? "touchid" : "faceid")
            }
            .disabled(method == nil)
            .accessibilityIdentifier("settings.appLock")
            if settings.appLock {
                Picker("Lock after", selection: $settings.lockDelay) {
                    ForEach(AppLockPolicy.delays, id: \.self) { d in
                        Text(label(for: d)).tag(d)
                    }
                }
            }
            Toggle(isOn: Binding(get: { keysProtected }, set: { on in
                switching = true
                Task {
                    let accounts = servers.flatMap { [$0.secretAccount, $0.secretAccount + ".passphrase"] }
                    if await KeyProtection.shared.setEnabled(on, accounts: accounts) { keysProtected = on }
                    switching = false
                }
            })) {
                Label(String(localized: "\(method ?? "Face ID") for server keys"), systemImage: "key.viewfinder")
            }
            .disabled(method == nil || switching)
            .accessibilityIdentifier("settings.keyProtection")
            #if DEBUG
            if ProcessInfo.processInfo.environment["DECKHAND_SHOW_KEY_STATE"] == "1", let first = servers.first {
                // UI tests: whether the first server's secret carries the Face ID access control.
                Text(!Keychain.exists(first.secretAccount) ? "keys: none" : Keychain.isProtected(first.secretAccount) ? "keys: protected" : "keys: plain")
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("settings.keyState")
            }
            #endif
        } header: {
            Text("Security")
        } footer: {
            if method == nil {
                Text("Set a passcode on this iPhone to use App Lock.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Deckhand asks for \(method ?? "Face ID") when it opens and after it was in the background, and hides its content in the app switcher. Background checks and notifications keep working.")
                    Text("With \(method ?? "Face ID") for server keys, passwords and keys can't be read without a check — one check keeps them open while you use the app and for 10 minutes after. While they're locked, background checks and notifications that need SSH pause; tasks already running on a server keep going and ntfy pushes from the server still arrive.")
                }
            }
        }
    }

    private func label(for delay: TimeInterval) -> String {
        switch delay {
        case 0: String(localized: "Immediately")
        case 3600: String(localized: "After 1 hour")
        default: String(localized: "After \(Int(delay / 60)) min")
        }
    }
}
