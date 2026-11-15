import DeckhandCore
import SwiftData
import SwiftUI

/// The morning briefing across all servers: what needs you today, what can wait, what was fixed — each line leads
/// into the tool for it. The reports are made on the servers at the chosen time; this screen reads them.
struct BriefingView: View {
    @Query(sort: \Server.name) private var servers: [Server]
    private var connections: Connections { .shared }
    @State private var states: [UUID: Briefing.State] = [:]
    @State private var errors: [UUID: String] = [:]
    @State private var running: Set<UUID> = []
    @State private var settingUp = false

    private var allItems: [Briefing.Item] { states.values.compactMap(\.report).flatMap { Briefing.items($0) } }
    private var attention: Int { allItems.filter { $0.level == .attention }.count }
    private var installedCount: Int { states.values.filter(\.installed).count }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(headline).font(.title2.weight(.semibold))
                        .accessibilityIdentifier("briefing.headline")
                    if installedCount == 0 && !states.isEmpty {
                        Text("Every morning, each server checks itself and tells you only what needs you.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Set Up Morning Briefing") { settingUp = true }
                            .buttonStyle(.borderedProminent).padding(.top, 4)
                            .accessibilityIdentifier("briefing.setup")
                    }
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }
            ForEach(ordered) { server in
                if let state = states[server.id], state.installed || state.report != nil {
                    ServerBriefing(server: server, state: state, running: running.contains(server.id)) {
                        Task { await runNow(server) }
                    }
                } else if let error = errors[server.id] {
                    Section(server.name) { ProblemView(message: error, compact: true) }
                }
            }
        }
        .navigationTitle("Morning Briefing")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { settingUp = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Briefing Settings")
                    .accessibilityIdentifier("briefing.settings")
            }
        }
        .appSheet(isPresented: $settingUp) {
            BriefingSetupSheet(servers: servers, states: states) { await loadAll() }
        }
        .refreshable { await loadAll() }
        .task { await loadAll() }
    }

    /// Servers with the most that needs you first, then by name.
    private var ordered: [Server] {
        func urgent(_ s: Server) -> Int {
            states[s.id]?.report.map { Briefing.items($0).filter { $0.level == .attention }.count } ?? 0
        }
        return servers.sorted { (urgent($0), $1.name) > (urgent($1), $0.name) }
    }

    private var headline: String {
        if states.isEmpty { return String(localized: "Checking your servers…") }
        if installedCount == 0 { return String(localized: "No briefing yet") }
        switch attention {
        case 0: return String(localized: "Nothing needs you today")
        case 1: return String(localized: "1 thing needs you today")
        default: return String(localized: "\(attention) things need you today")
        }
    }

    private func loadAll() async {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DECKHAND_SEED_BRIEFING"] == "demo" {
            for s in servers { states[s.id] = BriefingDemo.state(for: s.name) }
            return
        }
        #endif
        // All servers at once; each result lands as soon as it's there.
        let tasks = servers.map { server in
            Task { @MainActor in
                do {
                    let conn = try await Connections.shared.connection(for: server)
                    states[server.id] = Briefing.parse(try await conn.run(Briefing.readCommand, timeout: .seconds(30)).stdout)
                    errors[server.id] = nil
                } catch {
                    errors[server.id] = error.localizedDescription
                    if states[server.id] == nil { states[server.id] = Briefing.State() }
                }
            }
        }
        for t in tasks { await t.value }
    }

    private func runNow(_ server: Server) async {
        running.insert(server.id)
        defer { running.remove(server.id) }
        do {
            let conn = try await connections.connection(for: server)
            _ = try await conn.run(Briefing.runNowCommand, timeout: .seconds(180))
            states[server.id] = Briefing.parse(try await conn.run(Briefing.readCommand, timeout: .seconds(30)).stdout)
        } catch { errors[server.id] = error.localizedDescription }
    }
}

private struct ServerBriefing: View {
    let server: Server
    let state: Briefing.State
    let running: Bool
    let runNow: () -> Void

    var body: some View {
        Section {
            if let r = state.report {
                let items = Briefing.items(r)
                if items.isEmpty {
                    Label("All good", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                ForEach(items) { item in
                    NavigationLink { destination(item.tool) } label: { BriefingRow(item: item) }
                }
            } else {
                Text("The first report comes at the next briefing time.").foregroundStyle(.secondary)
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text(server.name)
                Spacer()
                if running { ProgressView().controlSize(.small) }
                else {
                    Menu {
                        Button { runNow() } label: { Label("Make Today's Report Now", systemImage: "arrow.clockwise") }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("More for \(server.name)")
                }
            }
        } footer: {
            if let r = state.report {
                let old = Date().timeIntervalSince(r.generated) > 26 * 3600
                Text(old ? String(localized: "Last report \(r.generated.formatted(.relative(presentation: .named))) — this server didn't report today.")
                         : String(localized: "Made \(r.generated.formatted(date: .omitted, time: .shortened)) on the server."))
                    .foregroundStyle(old ? .orange : .secondary)
            }
        }
        .accessibilityIdentifier("briefing.server.\(server.name)")
    }

    @ViewBuilder private func destination(_ tool: Briefing.Tool) -> some View {
        switch tool {
        case .updates: PackageUpdatesView(server: server)
        case .expiry: ExpiryView(server: server)
        case .disk: DiskUsageView(server: server)
        case .memory: MetricsHistoryView(server: server)
        case .services: ServicesView(server: server)
        case .cron: CronWatchView(server: server)
        case .logins: LoginAlertsView(server: server)
        case .rules: HouseRulesView(server: server)
        }
    }
}

private struct BriefingRow: View {
    let item: Briefing.Item

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(color).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(item.kind)).font(item.level == .attention ? .body.weight(.semibold) : .body)
                if case .diskFull(_, _, let grew) = item.kind, grew > 0 {
                    Text("Up \(grew) points since yesterday").font(.caption).foregroundStyle(.secondary)
                }
                if let d = item.detail { Text(verbatim: d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    static func title(_ kind: Briefing.Kind) -> String {
        switch kind {
        case .securityUpdates(let n): n == 1 ? String(localized: "1 security update") : String(localized: "\(n) security updates")
        case .otherUpdates(let n): n == 1 ? String(localized: "1 other update") : String(localized: "\(n) other updates")
        case .restartNeeded: String(localized: "Restart needed to finish updates")
        case .certificateExpiring(let d, let days):
            days < 0 ? String(localized: "Certificate for \(d) expired")
                : days == 0 ? String(localized: "Certificate for \(d) expires today") : days == 1 ? String(localized: "Certificate for \(d) expires tomorrow") : String(localized: "Certificate for \(d) expires in \(days) days")
        case .domainExpiring(let d, let days):
            days < 0 ? String(localized: "Domain \(d) expired")
                : days == 0 ? String(localized: "Domain \(d) expires today") : days == 1 ? String(localized: "Domain \(d) expires tomorrow") : String(localized: "Domain \(d) expires in \(days) days")
        case .diskFull(let m, let u, _): String(localized: "Disk \(m) is \(u)% full")
        case .diskGrew(let m, let p, let u): String(localized: "Disk \(m) grew \(p) points to \(u)%")
        case .memoryHigh(let u): String(localized: "Memory is \(u)% used")
        case .memoryRising(let a, let b): String(localized: "Memory use went up from \(a)% to \(b)% on average")
        case .servicesFailed(let n): n == 1 ? String(localized: "1 service failed") : String(localized: "\(n) services failed")
        case .cronFailed(let name): String(localized: "Cron job \(name) failed")
        case .cronLate(let name): String(localized: "Cron job \(name) didn't run on time")
        case .failedLogins(let n): n == 1 ? String(localized: "1 failed login in 24 hours") : String(localized: "\(n) failed logins in 24 hours")
        case .removedOldRuns(let n): n == 1 ? String(localized: "Removed 1 old task log") : String(localized: "Removed \(n) old task logs")
        case .shrankJournal(let a, let b): String(localized: "Shrank the system journal from \(a) MB to \(b) MB")
        case .clearedPackages(let mb): String(localized: "Cleared \(mb) MB of downloaded packages")
        case .noFixesReadOnly: String(localized: "No fixes: house rules are read-only")
        case .journalForbidden: String(localized: "Didn't shrink the journal: a house rule forbids it")
        case .packagesForbidden: String(localized: "Didn't clear the package cache: a house rule forbids it")
        case .journalNeedsSudo(let mb): String(localized: "The system journal uses \(mb) MB; shrinking it needs sudo without a password")
        }
    }

    private var symbol: String {
        switch item.level {
        case .attention: "exclamationmark.circle.fill"
        case .info: "info.circle"
        case .done: "checkmark.seal.fill"
        }
    }

    private var color: Color {
        switch item.level {
        case .attention: .orange
        case .info: .secondary
        case .done: .green
        }
    }
}

/// When the briefing comes, how loud it is, whether small fixes may happen, and on which servers.
struct BriefingSetupSheet: View {
    let servers: [Server]
    let states: [UUID: Briefing.State]
    let done: () async -> Void

    private var settings: AppSettings { .shared }
    @Environment(\.dismiss) private var dismiss
    @State private var time = Calendar.current.date(from: DateComponents(hour: 7, minute: 30)) ?? Date()
    @State private var quiet = true
    @State private var fixes = false
    @State private var included: Set<UUID> = []
    @State private var saving = false
    @State private var problems: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("briefing.time")
                    Toggle("Push only when something needs me", isOn: $quiet)
                } footer: {
                    Text("In your time zone (\(TimeZone.current.identifier)), on every server. The reports are made on the servers, so your phone can be off.")
                }
                Section {
                    Toggle("Small safe fixes", isOn: $fixes)
                        .accessibilityIdentifier("briefing.fixes")
                } footer: {
                    Text("Removes Deckhand task logs older than 30 days and, where sudo needs no password, shrinks a system journal over 1 GB and clears downloaded packages. Never when your house rules are read-only or forbid it. Everything done is listed in the briefing.")
                }
                Section("Servers") {
                    ForEach(servers) { s in
                        Toggle(s.name, isOn: Binding(get: { included.contains(s.id) }, set: { on in
                            if on { included.insert(s.id) } else { included.remove(s.id) }
                        }))
                    }
                }
                if !problems.isEmpty {
                    Section { ForEach(problems, id: \.self) { Text($0).foregroundStyle(.red) } }
                }
            }
            .navigationTitle("Morning Briefing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Save") { Task { await save() } }.accessibilityIdentifier("briefing.save")
                    }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        let installed = servers.filter { states[$0.id]?.installed == true }
        included = Set(installed.isEmpty ? servers.map(\.id) : installed.map(\.id))
        if let c = installed.compactMap({ states[$0.id]?.config }).first {
            // Shown in the user's time zone (stored that way).
            time = Calendar.current.date(from: DateComponents(hour: c.hour, minute: c.minute)) ?? time
            quiet = c.quiet; fixes = c.fixes
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        problems = []
        if settings.ntfyTopicURL.isEmpty { settings.ntfyTopicURL = TaskNotifier.newTopicURL() }
        TaskNotifier.shared.requestPermission()
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        let tasks: [Task<String?, Never>] = servers.compactMap { server in
            let on = included.contains(server.id), was = states[server.id]?.installed == true
            guard on || was else { return nil }
            let config = Briefing.Config(hour: c.hour ?? 7, minute: c.minute ?? 30, timeZone: TimeZone.current.identifier,
                                         topic: settings.ntfyTopicURL, name: server.name, quiet: quiet, fixes: fixes)
            let name = server.name
            return Task { @MainActor in
                do {
                    let conn = try await Connections.shared.connection(for: server)
                    let out = try await conn.run(on ? Briefing.installCommand(config) : Briefing.uninstallCommand, timeout: .seconds(30)).stdout
                    if out.contains("@@nocron") { return String(localized: "\(name): cron isn't installed on this server.") }
                    return out.contains("@@ok") ? nil : String(localized: "\(name): the server didn't accept the change.")
                } catch { return "\(name): \(error.localizedDescription)" }
            }
        }
        for t in tasks { if let p = await t.value { problems.append(p) } }
        await done()
        if problems.isEmpty { dismiss() }
    }
}

#if DEBUG
/// Demo reports for screenshots (DECKHAND_SEED_BRIEFING=demo), keyed by the seeded servers' names.
enum BriefingDemo {
    static func state(for name: String) -> Briefing.State {
        let t = Int(Date().timeIntervalSince1970) - 3_600
        let body: String
        switch name {
        case "web-1":
            body = """
            @@section updates
            @@pm apt
            @@list
            openssl/noble-security 3.0.13-0ubuntu3.4 amd64 [upgradable from: 3.0.13-0ubuntu3.1]
            libssl3t64/noble-security 3.0.13-0ubuntu3.4 amd64 [upgradable from: 3.0.13-0ubuntu3.1]
            htop/noble-updates 3.3.0-4build2 amd64 [upgradable from: 3.3.0-4build1]
            @@section expiry
            @@installed
            @@domain shop.example.com
            @@status shop.example.com\t\(t + 6 * 86_400)\tLet's Encrypt\t-\t\(t)
            @@section system
            @@disk / 87 2048000
            @@prevdisk / 81 3000000
            @@mem 58.0
            @@logins 214
            @@section fixes
            @@fix runs 9
            """
        case "db-1":
            body = """
            @@section updates
            @@pm apt
            @@list
            @@section cron
            @@job 0 3 * * * /home/me/dump.sh # deckhand-cronwatch ab12
            @@watch ab12\t86400\tnightly dump
            @@run ab12 \(t - 10_000) \(t - 9_990) 1
            @@out ab12 pg_dump: error: connection to server failed
            @@section system
            @@disk / 52 9000000
            @@mem 71.0
            @@memtrend 71.0 54.0
            @@logins 3
            @@section fixes
            @@fix journal 1840 500
            """
        default:
            body = """
            @@section updates
            @@pm apt
            @@list
            @@section system
            @@disk / 34 20000000
            @@mem 22.0
            @@logins 0
            """
        }
        return Briefing.parse("@@installed\n@@config BHOUR=07\n@@config BMIN=30\n@@briefing \(t) \(name)\n" + body)
    }
}
#endif
