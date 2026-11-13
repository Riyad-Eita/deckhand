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
        .sheet(item: $browsing) { BrowserSheet(server: server, port: $0.port, path: $0.path) }
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
    var id: String { "\(port)\(path)" }
}

/// An in-app browser for one port on the server, tunnelled over SSH while it's open.
struct BrowserSheet: View {
    let server: Server
    let port: Int
    var path: String = "/"
    @Environment(\.dismiss) private var dismiss
    @Environment(Connections.self) private var connections
    @State private var forward: PortForward?
    @State private var error: String?
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            Group {
                if let forward {
                    TunnelWebView(url: URL(string: path, relativeTo: forward.url)?.absoluteURL ?? forward.url, reloadToken: reloadToken)
                        .ignoresSafeArea(edges: .bottom)
                } else if let error {
                    VStack(spacing: 14) { Text("Couldn't open port \(String(port))").font(.title3.weight(.semibold)); ProblemView(message: error) }.frame(maxWidth: .infinity).padding(.vertical, 30)
                } else {
                    ProgressView("Opening a tunnel to port \(String(port))…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("\(server.displayName):\(String(port))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { reloadToken += 1 } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reload")
                }
            }
        }
        .task {
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

private struct TunnelWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int

    final class Coordinator { var token = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if context.coordinator.token != reloadToken { context.coordinator.token = reloadToken; view.reload() }
    }
}
