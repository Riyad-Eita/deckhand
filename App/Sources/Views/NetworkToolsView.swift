import DeckhandCore
import SwiftUI

/// Ping, traceroute, DNS, port and HTTP — from the server or from this iPhone — and "Ask an agent" with the result.
struct NetworkToolsView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var tool: NetworkTools.Tool = .ping
    @State private var fromPhone = false
    @State private var target = ""
    @State private var port = "443"
    @State private var dnsType = "A"
    @State private var result: NetworkTools.Result?
    @State private var ranFor: String?
    @State private var running = false
    @State private var error: String?
    @State private var investigatePrompt: String?
    @State private var showRaw = false

    var body: some View {
        List {
            Section {
                Picker("Tool", selection: $tool) { ForEach(NetworkTools.Tool.allCases) { Text($0 == .traceroute ? "Trace" : $0.title).tag($0) } }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("net.tool")
                Picker("From", selection: $fromPhone) {
                    Text(server.displayName).tag(false)
                    Text("This iPhone").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(!tool.onPhone)
                TextField(tool == .http ? "https://example.com" : "example.com", text: $target)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("net.target")
                if tool == .port {
                    TextField("Port", text: $port).keyboardType(.numberPad).accessibilityIdentifier("net.port")
                }
                if tool == .dns {
                    Picker("Record", selection: $dnsType) { ForEach(NetworkTools.dnsTypes, id: \.self) { Text($0).tag($0) } }
                }
                Button { Task { await run() } } label: {
                    HStack { Label("Run", systemImage: "play.fill"); Spacer(); if running { ProgressView() } }
                }
                .disabled(running || !NetworkTools.isValidTarget(NetworkTools.host(from: target)))
                .accessibilityIdentifier("net.run")
            } footer: {
                if !tool.onPhone { Text("Traceroute runs on the server — iPhones can't send it.") }
                else if fromPhone && tool == .ping { Text("From the iPhone, ping measures how long a connection to port 443 takes (iOS doesn't allow ICMP).") }
            }
            if let error { ProblemView(message: error, compact: true) }
            if let result, let ranFor {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: result.ok == true ? "checkmark.circle.fill" : result.ok == false ? "xmark.octagon.fill" : "info.circle")
                            .foregroundStyle(result.ok == true ? .green : result.ok == false ? .red : .secondary)
                        Text(ranFor).font(.subheadline.weight(.medium))
                    }
                    ForEach(result.summary, id: \.self) { Text($0).font(.callout.monospacedDigit()).textSelection(.enabled) }
                    if !result.raw.isEmpty {
                        DisclosureGroup("Full output", isExpanded: $showRaw) {
                            ScrollView(.horizontal) { Text(result.raw).font(Theme.monoSmall).textSelection(.enabled) }
                        }
                    }
                } header: { Text("Result") }
                .accessibilityIdentifier("net.result")
                Section {
                    Button { investigatePrompt = NetworkTools.agentPrompt(tool: tool, target: NetworkTools.host(from: target), fromPhone: fromPhone, result: result) } label: {
                        Label("Ask an agent about it", systemImage: "sparkle.magnifyingglass")
                    }
                    .accessibilityIdentifier("net.ask")
                }
            }
        }
        .navigationTitle("Network tools")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: tool) { if !tool.onPhone { fromPhone = false }; result = nil }
        .investigate(on: server, prompt: $investigatePrompt)
    }

    private func run() async {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        running = true
        defer { running = false }
        error = nil
        let host = NetworkTools.host(from: target)
        let p = Int(port) ?? 443
        let label = "\(tool.title) · \(host)\(tool == .port ? ":\(p)" : "") · " + (fromPhone ? String(localized: "from this iPhone") : String(localized: "from \(server.displayName)"))
        do {
            if fromPhone {
                result = try await PhoneNetwork.run(tool, host: host, port: p, dnsType: dnsType, url: target)
            } else {
                let conn = try await connections.connection(for: server)
                let out = try await conn.run(NetworkTools.serverCommand(tool, target: host, port: p, dnsType: dnsType, url: target), timeout: .seconds(90)).stdout
                result = NetworkTools.parse(tool, out)
            }
            ranFor = label
        } catch { self.error = error.localizedDescription }
    }
}

/// The tools that work from an iPhone: TCP connects, HTTP and DNS over HTTPS.
enum PhoneNetwork {
    static func run(_ tool: NetworkTools.Tool, host: String, port: Int, dnsType: String, url: String) async throws -> NetworkTools.Result {
        var r = NetworkTools.Result()
        switch tool {
        case .ping:
            var times: [Double] = []
            for _ in 0..<4 {
                let start = Date()
                if await PortProbe.isOpen(host: host, port: 443, timeout: .seconds(3)) { times.append(Date().timeIntervalSince(start) * 1000) }
            }
            r.ok = !times.isEmpty
            r.summary = ["\(times.count) of 4 connections to port 443"]
            if let avg = times.isEmpty ? nil : times.reduce(0, +) / Double(times.count) {
                r.summary.append(String(format: "%.0f ms average (%.0f–%.0f ms)", avg, times.min()!, times.max()!))
            }
        case .port:
            let start = Date()
            let open = await PortProbe.isOpen(host: host, port: port, timeout: .seconds(5))
            r.ok = open
            r.summary = [(open ? "Open" : "Closed or filtered") + String(format: " (%.0f ms)", Date().timeIntervalSince(start) * 1000)]
        case .http:
            let u = URL(string: url.hasPrefix("http") ? url : "https://\(host)/")!
            var req = URLRequest(url: u, timeoutInterval: 20)
            req.httpMethod = "GET"
            let start = Date()
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            r.ok = (200..<400).contains(code)
            r.summary = ["Status \(code)", String(format: "Total %.0f ms", Date().timeIntervalSince(start) * 1000)]
            if let final = resp.url, final.host != u.host || final.path != u.path { r.summary.append("Ended at \(final.absoluteString)") }
        case .dns:
            var c = URLComponents(string: "https://cloudflare-dns.com/dns-query")!
            c.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: dnsType)]
            var req = URLRequest(url: c.url!, timeoutInterval: 10)
            req.setValue("application/dns-json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            let answers = NetworkTools.parseDoH(data)
            r.ok = !answers.isEmpty
            r.summary = (answers.isEmpty ? ["No records"] : answers) + ["Answered by Cloudflare (DNS over HTTPS)"]
        case .traceroute:
            r.summary = ["Traceroute runs on the server."]
        }
        return r
    }
}
