import DeckhandCore
import SwiftUI

/// fail2ban: who is banned and why, unban, and keep your own address off the list.
struct Fail2banView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var root = RootRunner()
    @State private var unbanner = RootRunner()
    @State private var status: Fail2ban.Status?
    @State private var myAddress: String?
    @State private var countries: [String: String] = [:]
    @State private var task: RootTask?

    struct RootTask: Identifiable {
        let id = UUID()
        let change: ConfigChange
        let changeID: String
        let summary: String
    }

    private var bannedCount: Int { status?.jails.reduce(0) { $0 + $1.banned.count } ?? 0 }

    var body: some View {
        List {
            if let status {
                if !status.installed || !status.running {
                    Section {
                        Label(status.installed ? "fail2ban is installed but not running." : "fail2ban isn't installed.", systemImage: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                        Button("Set up fail2ban") {
                            let change = Hardening.fail2ban(sshPorts: status.sshPorts)
                            task = RootTask(change: change, changeID: ConfigChange.makeID(title: change.title),
                                            summary: String(localized: "Installs fail2ban if needed and bans addresses that keep failing to log in over SSH (and to your website, if nginx or Apache runs here) for an hour."))
                        }
                        .accessibilityIdentifier("fail2ban.setup")
                    } footer: {
                        Text("fail2ban watches the logs and blocks addresses that keep guessing passwords.")
                    }
                } else {
                    Section {
                        HStack(spacing: 24) {
                            stat("\(bannedCount)", "banned now")
                            stat("\(status.jails.reduce(0) { $0 + $1.totalBanned })", "banned so far")
                            stat("\(status.jails.reduce(0) { $0 + $1.totalFailed })", "failed attempts")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(status.jails) { jail in
                        Section {
                            if jail.banned.isEmpty {
                                Text("Nobody is banned right now.").foregroundStyle(.secondary)
                            }
                            ForEach(jail.banned, id: \.self) { ip in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ip).font(.body.monospaced())
                                        if let country = countries[ip] { Text(country).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Button("Unban") { Task { await unban(ip, jail: jail.name) } }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        } header: {
                            Text(LocalizedStringKey(jail.reason))
                        } footer: {
                            Text("Jail \(jail.name) · \(jail.currentlyFailed) failing right now")
                        }
                    }
                    Section {
                        let custom = status.ignored.filter { !["127.0.0.1/8", "127.0.0.0/8", "127.0.0.1", "::1"].contains($0) }
                        if custom.isEmpty { Text("Only this server itself.").foregroundStyle(.secondary) }
                        ForEach(custom, id: \.self) { Text($0).font(.body.monospaced()) }
                        if let me = myAddress, !status.ignored.contains(me) {
                            Button("Never ban my address (\(me))") {
                                if let change = Fail2ban.allowList(custom + [me]) {
                                    task = RootTask(change: change, changeID: ConfigChange.makeID(title: change.title),
                                                    summary: String(localized: "fail2ban will never ban \(me) — the address this iPhone reaches the server from right now. If you're on mobile data this address changes often."))
                                }
                            }
                            .accessibilityIdentifier("fail2ban.allowMe")
                        }
                    } header: {
                        Text("Never banned")
                    }
                }
            } else if case .failed(let m) = root.phase {
                ProblemView(message: m, compact: true)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Blocked logins")
        .task { if status == nil { await load() } }
        .refreshable { await load() }
        .sudoPassword(root, server: server)
        .sudoPassword(unbanner, server: server)
        .sheet(item: $task, onDismiss: { Task { await load() } }) { t in
            RootTaskSheet(server: server, title: LocalizedStringKey(t.change.title), summary: LocalizedStringKey(t.summary),
                          files: t.change.files, script: t.change.script(id: t.changeID), steps: RootTaskSheet.changeSteps)
        }
        .safeAreaInset(edge: .bottom) {
            if bannedCount > 0 {
                Text("Countries looked up at ipwho.is — only the banned addresses are sent.").font(.caption2).foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
        }
    }

    private func stat(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        if let conn = try? await connections.connection(for: server),
           let r = try? await conn.run(Fail2ban.myAddressCommand, timeout: .seconds(10)) {
            myAddress = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        guard await root.run(Fail2ban.statusScript, on: server) else { return }
        let s = Fail2ban.parse(root.lines.joined(separator: "\n"))
        status = s
        await lookUpCountries(s.jails.flatMap(\.banned).prefix(40).filter { countries[$0] == nil })
    }

    private func unban(_ ip: String, jail: String) async {
        guard let script = Fail2ban.unbanScript(ip, jail: jail) else { return }
        await unbanner.run(script, on: server)
        await load()
    }

    /// Country and flag per address from ipwho.is (HTTPS, no key).
    private func lookUpCountries(_ ips: [String]) async {
        await withTaskGroup(of: (String, String?).self) { group in
            for ip in ips {
                group.addTask {
                    guard let url = URL(string: "https://ipwho.is/\(ip)?fields=country,flag.emoji,connection.isp"),
                          let (data, _) = try? await URLSession.shared.data(from: url),
                          let j = try? JSONValue.parse(data), let country = j["country"]?.stringValue else { return (ip, nil) }
                    let flag = j["flag"]?["emoji"]?.stringValue ?? ""
                    let isp = j["connection"]?["isp"]?.stringValue.map { " · \($0)" } ?? ""
                    return (ip, "\(flag) \(country)\(isp)".trimmingCharacters(in: .whitespaces))
                }
            }
            for await (ip, text) in group { if let text { countries[ip] = text } }
        }
    }
}

