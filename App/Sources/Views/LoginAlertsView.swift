import DeckhandCore
import SwiftUI

/// A push for SSH logins from addresses you don't trust, and the list of recent logins.
struct LoginAlertsView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @Environment(AppSettings.self) private var settings
    @State private var root = RootRunner()
    @State private var status: LoginAlerts.Status?
    @State private var myAddress: String?
    @State private var countries: [String: String] = [:]
    @State private var task: RootTask?

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
                    LabeledContent("Login alerts") {
                        Text(status.enabled ? "On" : "Off").foregroundStyle(status.enabled ? .green : .secondary)
                    }
                    if !status.enabled {
                        Button("Turn on login alerts") { turnOn(status) }.accessibilityIdentifier("alerts.enable")
                    } else {
                        if status.topicURL != settings.ntfyTopicURL && !settings.ntfyTopicURL.isEmpty {
                            Button("Send alerts to this iPhone's ntfy topic") { turnOn(status) }
                        }
                        Button("Turn off", role: .destructive) {
                            task = RootTask(change: LoginAlerts.disable, changeID: ConfigChange.makeID(title: LoginAlerts.disable.title),
                                            summary: String(localized: "Removes the login hook from the server."))
                        }
                    }
                } footer: {
                    Text("Every SSH login from an address that isn't trusted sends a push with user, address, country and time — through your ntfy topic, straight from the server.")
                }
                Section {
                    if status.trusted.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                    ForEach(status.trusted, id: \.self) { ip in
                        HStack {
                            Text(ip).font(.body.monospaced())
                            if ip == myAddress { Text("this iPhone").font(.caption).foregroundStyle(.secondary) }
                        }
                        .swipeActions {
                            Button("Remove") { setTrusted(status.trusted.filter { $0 != ip }, status) }.tint(.red)
                        }
                    }
                    if let me = myAddress, !status.trusted.contains(me), status.enabled {
                        Button("Trust my current address (\(me))") { setTrusted(status.trusted + [me], status) }
                    }
                } header: {
                    Text("Trusted addresses")
                } footer: {
                    Text("No alerts for these. Deckhand trusts the address this iPhone connects from when you turn alerts on, so it doesn't alert you about itself.")
                }
                Section("Recent logins") {
                    if status.logins.isEmpty { Text("No logins found in the logs.").foregroundStyle(.secondary) }
                    ForEach(status.logins.prefix(30)) { login in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(login.user) · \(login.address)").font(.subheadline.monospaced())
                                Text([login.date, login.method == "publickey" ? String(localized: "key") : String(localized: "password"), countries[login.address]]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(login.method == "password" ? .orange : .secondary)
                            }
                            Spacer()
                            if status.trusted.contains(login.address) {
                                Image(systemName: "checkmark.seal").foregroundStyle(.green).accessibilityLabel("Trusted")
                            } else if status.enabled {
                                Button("Trust") { setTrusted(status.trusted + [login.address], status) }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }
            } else if case .failed(let m) = root.phase {
                ProblemView(message: m, compact: true)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Login alerts")
        .task { if status == nil { await load() } }
        .refreshable { await load() }
        .sudoPassword(root, server: server)
        .sheet(item: $task, onDismiss: { Task { await load() } }) { t in
            RootTaskSheet(server: server, title: LocalizedStringKey(t.change.title), summary: LocalizedStringKey(t.summary),
                          files: t.change.files, script: t.change.script(id: t.changeID), steps: RootTaskSheet.changeSteps,
                          guardID: t.change.guardSeconds != nil ? t.changeID : nil)
        }
    }

    private func turnOn(_ status: LoginAlerts.Status) {
        if settings.ntfyTopicURL.isEmpty { settings.ntfyTopicURL = TaskNotifier.newTopicURL() }
        let trusted = Array(Set(status.trusted + [myAddress].compactMap { $0 })).sorted()
        guard let change = LoginAlerts.enable(topicURL: settings.ntfyTopicURL, trusted: trusted) else { return }
        task = RootTask(change: change, changeID: ConfigChange.makeID(title: change.title),
                        summary: String(localized: "Adds a small login hook (PAM) that pushes to your ntfy topic. It can't block a login. Subscribe to the topic in the ntfy app: \(settings.ntfyTopicURL)"))
    }

    private func setTrusted(_ list: [String], _ status: LoginAlerts.Status) {
        guard let topic = status.topicURL ?? settings.ntfyTopicURL.nilIfEmpty else { return }
        let change = LoginAlerts.setTrusted(list, topicURL: topic)
        task = RootTask(change: change, changeID: ConfigChange.makeID(title: change.title),
                        summary: String(localized: "Trusted: \(list.isEmpty ? "—" : list.joined(separator: ", "))"))
    }

    private func load() async {
        if let conn = try? await connections.connection(for: server),
           let r = try? await conn.run(Fail2ban.myAddressCommand, timeout: .seconds(10)) {
            myAddress = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        guard await root.run(LoginAlerts.statusScript, on: server) else { return }
        let s = LoginAlerts.parse(root.lines.joined(separator: "\n"))
        status = s
        let unknown = Array(Set(s.logins.map(\.address))).filter { countries[$0] == nil }.prefix(20)
        await withTaskGroup(of: (String, String?).self) { group in
            for ip in unknown {
                group.addTask {
                    guard let url = URL(string: "https://ipwho.is/\(ip)?fields=country,flag.emoji"),
                          let (data, _) = try? await URLSession.shared.data(from: url),
                          let j = try? JSONValue.parse(data), let c = j["country"]?.stringValue else { return (ip, nil) }
                    return (ip, "\(j["flag"]?["emoji"]?.stringValue ?? "") \(c)".trimmingCharacters(in: .whitespaces))
                }
            }
            for await (ip, c) in group { if let c { countries[ip] = c } }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
