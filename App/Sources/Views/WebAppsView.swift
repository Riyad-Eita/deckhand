import DeckhandCore
import DeckhandSSH
import SwiftUI
import WebKit

/// Web apps running on the server — also ones that only listen on its localhost — opened through an SSH tunnel.
struct WebAppsView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var ports: [ListeningPorts.Port]?
    @State private var error: String?
    @State private var browsing: BrowserTarget?
    @State private var customPort = ""
    @State private var address = ""

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let ports {
                Section {
                    if ports.isEmpty { Text("Nothing listens on a port right now.").foregroundStyle(.secondary) }
                    ForEach(ports) { p in
                        Button { browsing = BrowserTarget(port: p.port) } label: {
                            HStack {
                                Text(String(p.port)).font(.body.monospacedDigit().weight(.medium)).frame(minWidth: 56, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.process ?? Firewall.wellKnown[p.port] ?? String(localized: "Unknown program"))
                                    Text(p.localOnly ? String(localized: "Only on the server") : String(localized: "Also reachable from outside"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "safari").foregroundStyle(Theme.accent)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("webapp.\(p.port)")
                    }
                } footer: {
                    Text("Opens through your SSH connection, so apps that only listen on the server's localhost (dev servers, admin panels) work too — nothing gets exposed to the internet.")
                }
                Section {
                    HStack {
                        TextField("https://shop.example.com", text: $address)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("webapp.address")
                        Button("Open") { if let url = BrowserTarget.publicURL(address) { browsing = BrowserTarget(port: 0, url: url) } }
                            .disabled(BrowserTarget.publicURL(address) == nil)
                            .accessibilityIdentifier("webapp.openAddress")
                    }
                } header: {
                    Text("Deployed app")
                } footer: {
                    Text("Its public address, straight from the iPhone.")
                }
                Section {
                    HStack {
                        TextField("Other port", text: $customPort).keyboardType(.numberPad).font(.body.monospacedDigit())
                        Button("Open") { if let p = Int(customPort), (1...65535).contains(p) { browsing = BrowserTarget(port: p) } }
                            .disabled(Int(customPort) == nil)
                    }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Web apps")
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $browsing) { BrowserSheet(server: server, port: $0.port, path: $0.path, publicURL: $0.url) }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            ports = ListeningPorts.parse(try await conn.run(ListeningPorts.command, timeout: .seconds(15)).stdout, hiding: [server.port, 22])
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct BrowserTarget: Identifiable, Hashable {
    let port: Int
    var path: String = "/"
    /// A public address (opened directly, no tunnel).
    var url: URL? = nil
    var id: String { url?.absoluteString ?? "\(port)\(path)" }

    /// "shop.example.com" or "https://…" → an http(s) URL with a host.
    static func publicURL(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "https://" + t }
        guard let url = URL(string: t), ["http", "https"].contains(url.scheme?.lowercased()), url.host()?.contains(".") == true else { return nil }
        return url
    }
}

/// An in-app browser for one port on the server, tunnelled over SSH while it's open.
struct BrowserSheet: View {
    let server: Server
    let port: Int
    var path: String = "/"
    var publicURL: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Connections.self) private var connections
    @State private var forward: PortForward?
    @State private var error: String?
    @State private var reloadToken = 0
    @State private var webView: WKWebView?
    @State private var shot: Data?
    @State private var showTo: ChatThread?

    var body: some View {
        NavigationStack {
            Group {
                if let publicURL {
                    TunnelWebView(url: publicURL, reloadToken: reloadToken) { webView = $0 }
                        .ignoresSafeArea(edges: .bottom)
                } else if let forward {
                    TunnelWebView(url: URL(string: path, relativeTo: forward.url)?.absoluteURL ?? forward.url, reloadToken: reloadToken) { webView = $0 }
                        .ignoresSafeArea(edges: .bottom)
                } else if let error {
                    VStack(spacing: 14) { Text("Couldn't open port \(String(port))").font(.title3.weight(.semibold)); ProblemView(message: error) }.frame(maxWidth: .infinity).padding(.vertical, 30)
                } else {
                    ProgressView("Opening a tunnel to port \(String(port))…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(publicURL?.host() ?? "\(server.displayName):\(String(port))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { reloadToken += 1 } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reload")
                        .accessibilityIdentifier("browser.reload")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await snapshot() } } label: { Image(systemName: "camera.viewfinder") }
                        .accessibilityLabel("Show the agent")
                        .accessibilityIdentifier("browser.showAgent")
                        .disabled(webView == nil)
                }
                if let url = webView?.url ?? publicURL, publicURL != nil {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Share link")
                            .accessibilityIdentifier("browser.share")
                    }
                }
            }
            .confirmationDialog("Show this page to", isPresented: Binding(get: { shot != nil }, set: { if !$0 { shot = nil } }), titleVisibility: .visible) {
                ForEach([Engine.claudeCode, .codex, .ownKey]) { engine in
                    Button(engine.title) { startTask(engine) }
                }
            } message: {
                Text("A new task starts with a screenshot of the page; add what to look at, then send.")
            }
            .navigationDestination(item: $showTo) { AgentChatView(thread: $0, server: server) }
        }
        .task {
            guard publicURL == nil else { return }
            do {
                let conn = try await connections.connection(for: server)
                forward = try await conn.forward(remotePort: port)
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onDisappear { forward?.stop() }
    }
}

extension BrowserSheet {
    /// A screenshot of the page as it looks now.
    @MainActor
    func snapshot() async {
        guard let webView else { return }
        guard let image = try? await webView.takeSnapshot(configuration: nil), let data = image.pngData() else { return }
        shot = ImagePrep.jpeg(data)
    }

    func startTask(_ engine: Engine) {
        guard let shot else { return }
        let thread = ChatThread(server: server, workingDirectory: server.recentDirectories.first ?? server.workingDirectory, engine: engine)
        thread.title = String(localized: "How the app looks")
        context.insert(thread)
        let where_ = webView?.url.map { publicURL != nil ? $0.absoluteString : String(localized: "port \(String(port)) on the server") } ?? ""
        PendingPrompt.setDraft(String(localized: "Here's how \(where_) looks right now: "), for: thread.id)
        PendingPrompt.setDraftImages([shot], for: thread.id)
        self.shot = nil
        showTo = thread
    }
}

private struct TunnelWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int
    var onView: (WKWebView) -> Void = { _ in }

    final class Coordinator { var token = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        DispatchQueue.main.async { onView(view) }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if context.coordinator.token != reloadToken { context.coordinator.token = reloadToken; view.reload() }
    }
}
