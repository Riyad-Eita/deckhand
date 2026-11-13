import DeckhandCore
import DeckhandSSH
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ServerEditorView: View {
    let server: Server?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Connections.self) private var connections

    @State private var name = ""
    @State private var group = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authKind: AuthKind = .key
    @State private var password = ""
    @State private var privateKey = ""
    @State private var passphrase = ""
    @State private var publicKey: String?
    @State private var importingKey = false
    @State private var testState: TestState = .idle
    @State private var loaded = false
    @State private var secretLocked = false
    /// The server created by "Test Connection", so Save updates it instead of adding a second one.
    @State private var created: Server?
    /// Replace the password with a freshly made key after a successful password login.
    @State private var switchToKey = true

    enum TestState: Equatable {
        case idle, running, ok(String), failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Host or IP", text: $host)
                        .textContentType(.URL).keyboardType(.URL)
                    TextField("User", text: $username)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    TextField("Name (optional)", text: $name)
                    TextField("Group (optional)", text: $group).accessibilityIdentifier("server.group")
                } header: {
                    Text("Server")
                } footer: {
                    Text("Tailscale names and IPs work too.")
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Section("Sign in with") {
                    Picker("Method", selection: $authKind) {
                        Text("SSH key").tag(AuthKind.key)
                        Text("Password").tag(AuthKind.password)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                    switch authKind {
                    case .password:
                        SecureField("Password", text: $password)
                        Toggle(isOn: $switchToKey) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Switch to a secure key")
                                Text("After the first connection Deckhand installs its own key on the server and forgets the password.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    case .key:
                        keySection
                    }
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            switch testState {
                            case .idle: EmptyView()
                            case .running: ProgressView()
                            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                            }
                        }
                    }
                    .disabled(!isValid || testState == .running)
                    if case .ok(let info) = testState {
                        Text(info).font(Theme.monoSmall).foregroundStyle(.secondary)
                    }
                    if case .failed(let error) = testState {
                        ProblemView(message: error, compact: true)
                    }
                }
            }
            .navigationTitle(server == nil ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        _ = save()
                        // Already in the Keychain; clearing the field keeps iOS from offering to save it as a web password.
                        password = ""
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
            .fileImporter(isPresented: $importingKey, allowedContentTypes: [.data, .text]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8) { privateKey = text; publicKey = nil }
            }
            .task {
                if server != nil, KeyProtection.shared.enabled { _ = await KeyProtection.shared.unlock() }
                load()
            }
        }
        .hostKeyPrompt(inSheet: true)
    }

    @ViewBuilder private var keySection: some View {
        if let publicKey {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add this public key to the server once:").font(.subheadline)
                Text(installCommand(publicKey))
                    .font(Theme.monoSmall)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("Copy Command") { UIPasteboard.general.string = installCommand(publicKey) }
                    Spacer()
                    ShareLink(item: publicKey) { Label("Share Key", systemImage: "square.and.arrow.up") }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }
        } else if privateKey.isEmpty {
            Button("Create a New Key") { generateKey() }
        }
        if privateKey.isEmpty || publicKey == nil {
            Button("Import Private Key…") { importingKey = true }
            TextField("…or paste an OpenSSH private key", text: $privateKey, axis: .vertical)
                .font(Theme.monoSmall)
                .lineLimit(3...6)
            if privateKey.contains("ENCRYPTED") || privateKey.contains("aes256") {
                SecureField("Key passphrase", text: $passphrase)
            }
        }
    }

    private func installCommand(_ key: String) -> String {
        "mkdir -p ~/.ssh && echo '\(key)' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
    }

    private var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(port) != nil
            && (authKind == .password ? !password.isEmpty : !privateKey.isEmpty)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let server else { return }
        name = server.name
        group = server.group
        host = server.host
        port = String(server.port)
        username = server.username
        authKind = server.authKind
        secretLocked = Keychain.isLocked(server.secretAccount)
        let secret = Keychain.get(server.secretAccount) ?? ""
        if authKind == .password { password = secret } else {
            privateKey = secret
            passphrase = Keychain.get(server.secretAccount + ".passphrase") ?? ""
            publicKey = SSHKeys.publicKeyLine(privateKey: secret, comment: "deckhand")
        }
    }

    private func generateKey() {
        let pair = SSHKeys.generateEd25519(comment: "deckhand@\(UIDevice.current.name.replacingOccurrences(of: " ", with: "-"))")
        privateKey = pair.privateKey
        publicKey = pair.publicKey
    }

    @discardableResult
    private func save() -> Server {
        let target = server ?? created ?? Server(name: "", host: "", username: "", authKind: authKind)
        let hostChanged = target.host != host.trimmingCharacters(in: .whitespaces) || target.port != Int(port) ?? 22
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.group = group.trimmingCharacters(in: .whitespaces)
        target.host = host.trimmingCharacters(in: .whitespaces)
        target.port = Int(port) ?? 22
        target.username = username.trimmingCharacters(in: .whitespaces)
        target.authKind = authKind
        if hostChanged { target.pinnedHostKey = nil }
        if server == nil && created == nil {
            context.insert(target)
            created = target
        }
        // Locked by Face ID and left empty: keep what's saved instead of erasing it.
        if !(secretLocked && (authKind == .password ? password : privateKey).isEmpty) {
            Keychain.set(authKind == .password ? password : privateKey, for: target.secretAccount)
            Keychain.set(authKind == .key ? passphrase : nil, for: target.secretAccount + ".passphrase")
        }
        return target
    }

    /// Creates a key, adds it to authorized_keys, proves a key login works, then drops the password.
    private func installKey(on target: Server, using conn: SSHConnection) async throws {
        let device = UIDevice.current.name.replacingOccurrences(of: " ", with: "-")
        let pair = SSHKeys.generateEd25519(comment: "deckhand@\(device)")
        let r = try await conn.run(KeyInstall.command(publicKey: pair.publicKey), timeout: .seconds(20))
        guard KeyInstall.succeeded(r) else {
            throw ToolError.failed("Could not add the key on the server: \(r.stderr.isEmpty ? "exit \(r.exitCode)" : r.stderr)")
        }
        // Prove the key works before forgetting the password.
        let probe = SSHConnection(
            endpoint: SSHEndpoint(host: target.host, port: target.port, username: target.username),
            credential: .privateKey(pair.privateKey, passphrase: nil))
        try await probe.connect(pinnedHostKey: target.pinnedHostKey) { _, _ in false }
        await probe.disconnect()
        Keychain.set(pair.privateKey, for: target.secretAccount)
        target.authKind = .key
        authKind = .key
        privateKey = pair.privateKey
        publicKey = pair.publicKey
        password = ""
        await connections.disconnect(target)
    }

    private func test() async {
        testState = .running
        let target = save()
        await connections.disconnect(target)
        do {
            let conn = try await connections.connection(for: target)
            let r = try await conn.run("uname -sr; whoami", timeout: .seconds(15))
            var info = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if authKind == .password && switchToKey {
                try await installKey(on: target, using: conn)
                info += "\nSecure key installed — the password is no longer stored."
            }
            testState = .ok(info)
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }
}
