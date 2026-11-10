import DeckhandCore
import SwiftUI

/// Firewall rules with presets, guarded changes that can't lock you out, and a check from the outside.
struct FirewallView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var root = RootRunner()
    @State private var status: Firewall.Status?
    @State private var task: RootTask?
    @State private var adding = false
    @State private var scan: [Int]?
    @State private var listening: Set<Int> = []
    @State private var scanning = false
    @State private var investigatePrompt: String?

    struct RootTask: Identifiable {
        let id = UUID()
        let change: ConfigChange
        let changeID: String
        let summary: String
    }

    var body: some View {
        List {
            if let status {
                Section {
                    LabeledContent("Firewall", value: status.kind == .none ? String(localized: "None installed") : status.kind.rawValue)
                    LabeledContent("State") {
                        Text(status.active ? "Active" : "Off").foregroundStyle(status.active ? .green : .orange)
                    }
                    if !status.active && status.kind != .firewalld {
                        Button("Turn on: block everything except SSH and web") {
                            let change = Hardening.ufw(open: Array(Set(status.sshPorts + [80, 443])).sorted())
                            task = RootTask(change: change, changeID: ConfigChange.makeID(title: change.title),
                                            summary: String(localized: "Incoming connections are blocked except SSH (port \(status.sshPorts.map(String.init).joined(separator: ", "))) and web (80, 443). Deckhand logs in again before keeping it."))
                        }
                    }
                }
                if status.active {
                    Section {
                        ForEach(status.rules) { rule in ruleRow(rule, status: status) }
                        Button { adding = true } label: { Label("Add a rule", systemImage: "plus") }
                            .accessibilityIdentifier("firewall.add")
                    } header: {
                        Text("Allowed")
                    } footer: {
                        Text("Swipe to remove a rule. The rule that lets Deckhand reach SSH can't be removed. Every change is checked with a fresh login and undone by itself if that fails.")
                    }
                }
                outsideSection
            } else if case .failed(let m) = root.phase {
                Text(m).foregroundStyle(.red).font(.footnote)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Firewall")
        .task { if status == nil { await load() } }
        .refreshable { await load() }
        .sudoPassword(root, server: server)
        .investigate(on: server, prompt: $investigatePrompt)
        .sheet(item: $task, onDismiss: { Task { await load() } }) { t in
            RootTaskSheet(server: server, title: LocalizedStringKey(t.change.title), summary: LocalizedStringKey(t.summary),
                          files: t.change.files, script: t.change.script(id: t.changeID), steps: RootTaskSheet.changeSteps,
                          guardID: t.change.guardSeconds != nil ? t.changeID : nil)
        }
        .sheet(isPresented: $adding) {
            if let status {
                AddRuleSheet { rule in
                    let change = Firewall.add(rule, to: status)
                    task = RootTask(change: change, changeID: ConfigChange.makeID(title: change.title),
                                    summary: String(localized: "Opens port \(rule.port)/\(rule.proto.rawValue)\(rule.from.map { " " + String(localized: "for \($0) only") } ?? "") in the firewall."))
                }
            }
        }
    }

    @ViewBuilder private func ruleRow(_ rule: Firewall.Rule, status: Firewall.Status) -> some View {
        let protected = Firewall.protects(rule, in: status)
        HStack(spacing: 10) {
            Text(rule.action == "ALLOW" ? "✓" : rule.action == "LIMIT" ? "≈" : "✕")
                .font(.caption.weight(.bold)).foregroundStyle(rule.action == "ALLOW" || rule.action == "LIMIT" ? .green : .red).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.target).font(.body.monospaced())
                    if rule.ipv6 { Text("IPv6").font(.caption2).foregroundStyle(.secondary) }
                    if protected != nil { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                }
                Text([rule.from == "Anywhere" ? String(localized: "from anywhere") : String(localized: "from \(rule.from)"), rule.comment].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .swipeActions {
            if protected == nil {
                // Not `role: .destructive`: that makes the list drop the row at once, before the change is confirmed.
                Button("Remove") {
                    let change = Firewall.remove(rule, from: status)
                    let next = RootTask(change: change, changeID: ConfigChange.makeID(title: change.title),
                                        summary: String(localized: "Removes the rule \(rule.target)\(rule.from == "Anywhere" ? "" : " " + rule.from)."))
                    // Let the swipe close first: a sheet over an open swipe action can crash the list's batch update.
                    Task { try? await Task.sleep(for: .milliseconds(400)); task = next }
                }
                .tint(.red)
            }
        }
    }

    // MARK: Outside check

    private var outsideSection: some View {
        Section {
            Button {
                Task { await runScan() }
            } label: {
                HStack {
                    Label("Check from outside", systemImage: "dot.radiowaves.left.and.right")
                    Spacer()
                    if scanning { ProgressView() }
                }
            }
            .disabled(scanning)
            .accessibilityIdentifier("firewall.scan")
            if let scan {
                if scan.isEmpty {
                    Text("No common port answered.").foregroundStyle(.secondary)
                }
                ForEach(scan, id: \.self) { port in
                    let exposure = Firewall.exposure(port: port, sshPort: server.port)
                    HStack(spacing: 10) {
                        Circle().fill(exposure == .expected ? .green : exposure == .risky ? .red : .orange).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(String(port)) · \(port == server.port ? "SSH" : Firewall.wellKnown[port] ?? String(localized: "unknown service"))")
                            Text(explanation(exposure, port: port)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if exposure != .expected {
                            Button("Fix") {
                                investigatePrompt = "Port \(port) (\(Firewall.wellKnown[port] ?? "unknown")) on this server answers from the internet. Find out which process listens on it and why it's reachable (firewall rule, Docker port mapping that bypasses the firewall, or a service bound to 0.0.0.0). Suggest the safest way to make it private without breaking what uses it. Ask me before changing anything."
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                // Behind port forwarding sshd's own port isn't dialled directly — don't list it as hidden.
                let forwarded = status.map { !$0.sshPorts.contains(server.port) } ?? false
                let hidden = listening.subtracting(scan)
                    .filter { Firewall.wellKnown[$0] != nil || $0 == server.port }
                    .filter { !(forwarded && (status?.sshPorts.contains($0) ?? false)) }.sorted()
                if !hidden.isEmpty {
                    Text("Listening but not reachable from here: \(hidden.map(String.init).joined(separator: ", ")) — the firewall keeps them private.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Open to the outside")
        } footer: {
            Text("Tries common ports from the network this iPhone is on. On the same Wi-Fi as the server you see more than the internet does — use mobile data for the real outside view.")
        }
    }

    private func explanation(_ e: Firewall.Exposure, port: Int) -> String {
        switch e {
        case .expected: String(localized: "Meant to be public.")
        case .risky: String(localized: "Shouldn't be reachable from the internet.")
        case .review: String(localized: "Make sure this should be public.")
        }
    }

    private func load() async {
        guard await root.run(Firewall.statusScript, on: server) else { return }
        status = Firewall.parse(root.lines.joined(separator: "\n"))
    }

    private func runScan() async {
        scanning = true
        defer { scanning = false }
        if let conn = try? await connections.connection(for: server),
           let r = try? await conn.run("ss -ltnH 2>/dev/null | awk '{n=split($4,a,\":\"); print a[n]}' | sort -un", timeout: .seconds(15)) {
            listening = Set(r.stdout.split(separator: "\n").compactMap { Int($0) })
        }
        let ports = Array(Firewall.wellKnown.keys) + [server.port] + listening.filter { $0 < 49152 }
        scan = await PortProbe.openPorts(host: server.host, ports: ports, timeout: .seconds(3))
    }
}

/// A new firewall rule from a preset or by hand.
private struct AddRuleSheet: View {
    let add: (Firewall.NewRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var port = ""
    @State private var proto: Firewall.Proto = .tcp
    @State private var from = ""
    @State private var comment = ""

    var rule: Firewall.NewRule {
        Firewall.NewRule(port: port.replacingOccurrences(of: " ", with: ""), proto: proto,
                         from: from.trimmingCharacters(in: .whitespaces).isEmpty ? nil : from.trimmingCharacters(in: .whitespaces), comment: comment)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Presets") {
                    Button("Website (80, 443)") { port = "80,443"; proto = .tcp; from = ""; comment = "Web" }
                    Button("PostgreSQL for one address (5432)") { port = "5432"; proto = .tcp; comment = "PostgreSQL" }
                    Button("MySQL for one address (3306)") { port = "3306"; proto = .tcp; comment = "MySQL" }
                }
                Section {
                    TextField("Port, list or range (8080, 80,443, 6000:6007)", text: $port).keyboardType(.numbersAndPunctuation)
                        .font(.body.monospaced()).accessibilityIdentifier("rule.port")
                    Picker("Protocol", selection: $proto) { ForEach(Firewall.Proto.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) } }
                        .pickerStyle(.segmented)
                    TextField("Only from (address or network, optional)", text: $from).keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never).font(.body.monospaced())
                    TextField("Note (optional)", text: $comment)
                } footer: {
                    if !port.isEmpty && !rule.isValid { Text("Check the port and address.").foregroundStyle(.orange) }
                    else if (port == "5432" || port == "3306") && from.isEmpty { Text("Databases should only be open for the addresses that need them.").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Allow a port")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") { let r = rule; dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { add(r) } }
                        .disabled(!rule.isValid).accessibilityIdentifier("rule.next")
                }
            }
        }
    }
}
