import DeckhandCore
import DeckhandSSH
import SwiftUI
import UIKit

/// Sets up a fresh server securely in one go: admin user with this iPhone's key, root and password logins off
/// (only after the key login worked), firewall, fail2ban, automatic updates, time sync and swap.
struct ProvisionView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var root = RootRunner()
    @State private var follow = RootRunner()
    @State private var facts: SecurityAudit.Facts?
    @State private var username = "deploy"
    @State private var sudoPassword = Provisioning.generatePassword()
    @State private var options: Set<Option> = []
    @State private var steps: [Step] = []
    @State private var running = false
    @State private var finished = false
    @State private var confirmStart = false
    @State private var copied = false

    enum Option: String, CaseIterable, Identifiable {
        case firewall, fail2ban, autoUpdates, timeSync, swap
        var id: String { rawValue }
    }

    struct Step: Identifiable, Equatable {
        enum State: Equatable { case waiting, running, done, failed, skipped }
        let id: String
        let title: String
        var state: State = .waiting
        var note: String?
    }

    private var isRoot: Bool { facts?["whoami"] == "root" }
    private var sshPorts: [Int] { facts?.list("ssh.ports").compactMap(Int.init) ?? [22] }

    var body: some View {
        List {
            if let facts {
                if !isRoot {
                    Section {
                        Label("Log in as root to set up a fresh server. You're logged in as \(facts["whoami"]) — the security check-up can harden this server instead.", systemImage: "info.circle")
                            .font(.subheadline)
                        NavigationLink("Open the security check-up") { SecurityAuditView(server: server) }
                    }
                } else if steps.isEmpty {
                    form(facts)
                }
                if !steps.isEmpty { progress }
                if finished { report }
            } else if case .failed(let m) = root.phase {
                ProblemView(message: m, compact: true)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Secure a fresh server")
        .task { if facts == nil { await inspect() } }
        .sudoPassword(root, server: server)
        .sudoPassword(follow, server: server)
        .confirmationDialog("Set up \(server.displayName)?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Set up") { Task { await provision() } }
        } message: {
            Text("Afterwards you log in as \(username) with this iPhone's key; root and password logins are turned off. Keep the sudo password somewhere safe.")
        }
        .interactiveDismissDisabled(running)
    }

    // MARK: Form

    @ViewBuilder private func form(_ f: SecurityAudit.Facts) -> some View {
        Section {
            LabeledContent("System", value: f["os"])
            LabeledContent("Memory", value: "\(f["memmb"]) MB")
        }
        Section {
            TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.body.monospaced()).accessibilityIdentifier("provision.username")
            if !Provisioning.isValidUsername(username) {
                Text("Use lowercase letters, digits, - or _, and not a system name.").font(.footnote).foregroundStyle(.orange)
            }
            HStack {
                Text(sudoPassword).font(.body.monospaced()).textSelection(.enabled)
                Spacer()
                Button(copied ? "Copied" : "Copy") { UIPasteboard.general.string = sudoPassword; copied = true }
                Button { sudoPassword = Provisioning.generatePassword(); copied = false } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("New password")
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Admin user")
        } footer: {
            Text("Deckhand logs in as this user with a key it creates on this iPhone. The password is for sudo — save it in your password manager.")
        }
        Section {
            if f["firewall"] == "none" { Toggle("Firewall: block everything except SSH and open web ports", isOn: binding(.firewall)) }
            if f["fail2ban"] != "active" { Toggle("Block repeated failed logins (fail2ban)", isOn: binding(.fail2ban)) }
            if f["pm"] == "apt" && f["autoupdates"] != "yes" { Toggle("Automatic security updates", isOn: binding(.autoUpdates)) }
            if f["timesync"] != "yes" { Toggle("Keep the clock in sync", isOn: binding(.timeSync)) }
            if canAddSwap(f) { Toggle("Add \(Provisioning.swapSize(memoryMB: f.int("memmb") ?? 1024)) MB of swap", isOn: binding(.swap)) }
        } header: {
            Text("Also")
        } footer: {
            Text("Every change is backed up first and shows up in the change history, where you can roll it back.")
        }
        Section {
            ForEach(Array(plan.enumerated()), id: \.element.id) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(i + 1)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary).frame(width: 20)
                    Text(step.title).font(.subheadline)
                }
            }
        } header: {
            Text("What happens")
        } footer: {
            Text("Root and password logins are only turned off after the key login as \(username) worked. Steps that could lock you out roll back by themselves unless Deckhand can log in again.")
        }
        Section {
            Button { confirmStart = true } label: { Text("Set up the server").frame(maxWidth: .infinity) }
                .disabled(!Provisioning.isValidUsername(username) || running)
                .accessibilityIdentifier("provision.start")
        }
    }

    /// Containers (Docker, LXC, OpenVZ) can't have their own swap.
    private func canAddSwap(_ f: SecurityAudit.Facts) -> Bool {
        (f.int("swap") ?? 0) == 0 && (f["container"].isEmpty || f["container"] == "none")
    }

    private func binding(_ o: Option) -> Binding<Bool> {
        Binding(get: { options.contains(o) }, set: { if $0 { options.insert(o) } else { options.remove(o) } })
    }

    // MARK: Progress and report

    private var progress: some View {
        Section("Progress") {
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 10) {
                    icon(step.state).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                        if let note = step.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private var report: some View {
        Section {
            let failed = steps.filter { $0.state == .failed }
            Label(failed.isEmpty ? "Your server is set up." : (failed.count == 1 ? "Set up — 1 step needs a look." : "Set up — \(failed.count) steps need a look."),
                  systemImage: failed.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield")
                .foregroundStyle(failed.isEmpty ? .green : .orange)
            LabeledContent("Login", value: "\(server.username) · key")
            LabeledContent("Sudo password") {
                Button(copied ? "Copied" : "Copy") { UIPasteboard.general.string = sudoPassword; copied = true }
            }
            NavigationLink("Next: move SSH off port 22") { SSHPortView(server: server) }
            NavigationLink("Run the security check-up") { SecurityAuditView(server: server) }
        }
    }

    @ViewBuilder private func icon(_ s: Step.State) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    // MARK: Running

    private func inspect() async {
        guard await root.run(Provisioning.inspectScript, on: server) else { return }
        let f = SecurityAudit.parse(root.lines.joined(separator: "\n"))
        facts = f
        if f["firewall"] == "none" { options.insert(.firewall) }
        if f["fail2ban"] != "active" { options.insert(.fail2ban) }
        if f["pm"] == "apt" && f["autoupdates"] != "yes" { options.insert(.autoUpdates) }
        if f["timesync"] != "yes" { options.insert(.timeSync) }
        if canAddSwap(f) && (f.int("diskfreemb") ?? 0) > 8000 { options.insert(.swap) }
    }

    private func set(_ id: String, _ state: Step.State, note: String? = nil) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].state = state
        if let note { steps[i].note = note }
    }

    private func provision() async {
        guard let facts else { return }
        running = true
        defer { running = false; finished = true }
        let user = username
        steps = plan

        // 1. Admin user — the password reaches the server over stdin only.
        let pair = SSHKeys.generateEd25519(comment: "deckhand@\(UIDevice.current.name.replacingOccurrences(of: " ", with: "-"))")
        set("user", .running)
        guard await root.run(Provisioning.createAdminScript(username: user, publicKey: pair.publicKey), on: server, input: [sudoPassword]) else {
            set("user", .failed, note: root.lines.last); skipRest(); return
        }
        set("user", .done)

        // 2. Prove the key login, then switch the saved server to it.
        set("login", .running)
        do {
            let conn = try await connections.testLogin(server, port: server.port, username: user, credential: .privateKey(pair.privateKey, passphrase: nil))
            server.username = user
            server.authKind = .key
            Keychain.set(pair.privateKey, for: server.secretAccount)
            Keychain.set(nil, for: server.secretAccount + ".passphrase")
            RootAccess.shared.reset(server)
            RootAccess.shared.setPassword(sudoPassword, for: server)
            await connections.adopt(conn, for: server, port: server.port)
            set("login", .done)
        } catch {
            set("login", .failed, note: String(localized: "Root and password logins stay on. \(error.localizedDescription)"))
            skipRest(); return
        }

        // 3. Root and password logins off — guarded with a fresh key login.
        let ssh = Hardening.ssh(context: .init(loginUser: user, usesKey: true), includeEnabled: facts["ssh.include"] == "yes")
        await guarded("ssh", ssh)

        if options.contains(.firewall) {
            let keep = Array(Set(sshPorts + facts.list("public").compactMap(Int.init).filter { SecurityAudit.riskyPorts[$0] == nil })).sorted()
            await guarded("firewall", Hardening.ufw(open: keep))
        }
        if options.contains(.fail2ban) { await plain("fail2ban", Hardening.fail2ban(sshPorts: sshPorts)) }
        if options.contains(.autoUpdates) { await plain("updates", Hardening.unattendedUpgrades) }
        if options.contains(.timeSync) {
            set("time", .running)
            set("time", await root.run(Provisioning.timeSyncScript, on: server) ? .done : .failed, note: root.succeeded ? nil : root.lines.last)
        }
        if options.contains(.swap) { await plain("swap", Provisioning.swap(megabytes: Provisioning.swapSize(memoryMB: facts.int("memmb") ?? 1024))) }
    }

    /// Every step, in order — shown before starting and then as the progress list.
    private var plan: [Step] {
        var p = [
            Step(id: "user", title: String(localized: "Create \(username) with sudo and this iPhone's key")),
            Step(id: "login", title: String(localized: "Log in as \(username) with the key")),
            Step(id: "ssh", title: String(localized: "Turn off root and password logins")),
        ]
        if options.contains(.firewall) { p.append(Step(id: "firewall", title: String(localized: "Turn on the firewall"))) }
        if options.contains(.fail2ban) { p.append(Step(id: "fail2ban", title: String(localized: "Block repeated failed logins"))) }
        if options.contains(.autoUpdates) { p.append(Step(id: "updates", title: String(localized: "Turn on automatic security updates"))) }
        if options.contains(.timeSync) { p.append(Step(id: "time", title: String(localized: "Keep the clock in sync"))) }
        if options.contains(.swap) { p.append(Step(id: "swap", title: String(localized: "Add swap"))) }
        return p
    }

    private func skipRest() {
        for i in steps.indices where steps[i].state == .waiting { steps[i].state = .skipped }
    }

    private func plain(_ id: String, _ change: ConfigChange) async {
        set(id, .running)
        let ok = await root.run(change.script(id: ConfigChange.makeID(title: change.title)), on: server)
        set(id, ok ? .done : .failed, note: ok ? nil : String(localized: "Undone automatically (\(root.failedStep ?? "error")).") )
    }

    /// Applies a change that could lock us out, logs in afresh and only then keeps it.
    private func guarded(_ id: String, _ change: ConfigChange) async {
        set(id, .running)
        let cid = ConfigChange.makeID(title: change.title)
        guard await root.run(change.script(id: cid), on: server) else {
            set(id, .failed, note: String(localized: "Undone automatically (\(root.failedStep ?? "error")).")); return
        }
        do {
            let fresh = try await connections.testLogin(server, port: server.port)
            guard await follow.run(ConfigChange.confirmScript(id: cid), on: server, connection: fresh) else { throw CLIError("confirm") }
            await connections.adopt(fresh, for: server, port: server.port)
            set(id, .done)
        } catch {
            await follow.run(ConfigChange.rollbackScript(id: cid), on: server)
            set(id, .failed, note: String(localized: "A fresh login failed, so this was rolled back."))
        }
    }
}
