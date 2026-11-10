import DeckhandCore
import DeckhandSSH
import SwiftUI
import WebKit

/// Signs Claude Code or Codex in on the server with the provider's real sign-in page.
/// The CLI's own login runs in a hidden terminal on the server; the app shows the page and hands back the result.
struct CLILoginView: View {
    let server: Server
    let cli: ServerCLI
    var onFinished: (Bool) -> Void = { _ in }

    enum Phase: Equatable {
        case starting
        case signIn(URL)
        case submitting
        case done
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(Connections.self) private var connections
    @State private var phase: Phase = .starting
    @State private var deviceCode: String?
    @State private var session: TerminalSession?
    @State private var parser: CLILoginParser
    @State private var manualCode = ""
    @State private var showManual = false
    @State private var submitted = false

    init(server: Server, cli: ServerCLI, onFinished: @escaping (Bool) -> Void = { _ in }) {
        self.server = server
        self.cli = cli
        self.onFinished = onFinished
        _parser = State(initialValue: CLILoginParser(cli: cli))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .starting:
                    progress("Starting \(cli.displayName) sign-in on \(server.displayName)…")
                case .signIn(let url):
                    VStack(spacing: 0) {
                        if let deviceCode { DeviceCodeBanner(code: deviceCode) }
                        LoginWebView(url: url) { callback in
                            if cli == .claudeCode, let code = ClaudeOAuth.code(fromCallback: callback) { submit(code) }
                        }
                        fallbackBar(url)
                    }
                case .submitting:
                    progress("Finishing sign-in on the server…")
                case .done:
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(.green)
                        Text("\(cli.displayName) is signed in on \(server.displayName)").font(.headline).multilineTextAlignment(.center)
                        Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                    }
                    .padding()
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Sign-in didn't finish", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await start() } }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Sign in to \(cli.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(phase == .done ? "Close" : "Cancel") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        BrandIcon(brand: cli.brand, size: 22)
                        Text("Sign in to \(cli.displayName)").font(.subheadline.weight(.semibold))
                    }
                }
            }
            .alert("Paste the code", isPresented: $showManual) {
                TextField("Code from the page", text: $manualCode)
                Button("Submit") { submit(manualCode.trimmingCharacters(in: .whitespacesAndNewlines)) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("After signing in, the page shows a code. Copy it and paste it here.")
            }
        }
        .task { await start() }
        .onChange(of: scenePhase) { _, now in
            // Coming back from Safari with the code copied: use it right away.
            guard now == .active, cli == .claudeCode, case .signIn = phase, UIPasteboard.general.hasStrings,
                  let text = UIPasteboard.general.string, ClaudeOAuth.looksLikeCode(text) else { return }
            submit(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .onDisappear {
            session?.close()
            onFinished(phase == .done)
        }
        .hostKeyPrompt(inSheet: true)
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func fallbackBar(_ url: URL) -> some View {
        HStack {
            Button { UIApplication.shared.open(url) } label: { Label("Open in Safari", systemImage: "safari") }
            Spacer()
            if cli == .claudeCode {
                Button("Paste Code…") { showManual = true }
            }
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private func start() async {
        phase = .starting
        deviceCode = nil
        submitted = false
        parser = CLILoginParser(cli: cli)
        session?.close()
        do {
            let connection = try await connections.connection(for: server)
            let terminal = try await connection.openTerminal(cols: 400, rows: 50)
            session = terminal
            terminal.send(parser.command + "\n")
            for await chunk in terminal.output {
                for event in parser.feed(String(decoding: chunk, as: UTF8.self)) { await handle(event) }
                if phase == .done { break }
            }
            // The CLI exited (exec): confirm with the real status instead of trusting the text.
            if phase != .done { await confirm() }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func handle(_ event: CLILoginEvent) async {
        switch event {
        case .openURL(let url): phase = .signIn(url)
        case .deviceCode(let code): deviceCode = code
        case .waitingForCode: break
        case .succeeded: await confirm()
        case .failed(let why): phase = .failed("The server reported: \(why). Start again to get a fresh sign-in link.")
        }
    }

    private func submit(_ code: String) {
        guard !code.isEmpty, !submitted, let session else { return }
        submitted = true
        phase = .submitting
        session.send(code + "\r")
    }

    private func confirm() async {
        guard let conn = try? await connections.connection(for: server),
              let r = try? await conn.run(ServerInventory.probeCommand, timeout: .seconds(40)) else {
            phase = .failed("Couldn't check the result.")
            return
        }
        let state = ServerInventory.parse(r.stdout).state(for: cli)
        phase = state.loggedIn ? .done : (phase == .submitting ? .failed("The code wasn't accepted. Start again for a fresh link.") : phase)
    }
}

private struct DeviceCodeBanner: View {
    let code: String
    @State private var copied = false
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Enter this code on the page").font(.caption).foregroundStyle(.secondary)
                Text(code).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
            }
            Spacer()
            Button(copied ? "Copied" : "Copy") {
                UIPasteboard.general.string = code
                copied = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.bar)
    }
}

/// The provider's sign-in page. Reports every navigation so the app can pick up the authorization callback.
struct LoginWebView: UIViewRepresentable {
    let url: URL
    let onNavigate: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onNavigate: onNavigate) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onNavigate: (URL) -> Void
        init(onNavigate: @escaping (URL) -> Void) { self.onNavigate = onNavigate }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if let url = action.request.url { await MainActor.run { onNavigate(url) } }
            return .allow
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let url = webView.url { onNavigate(url) }
        }
    }
}
