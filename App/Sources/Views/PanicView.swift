import DeckhandCore
import LocalAuthentication
import SwiftUI

/// The panic button: when this server looks compromised, save the evidence and lock it down in one guarded step.
struct PanicView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var myAddress = ""
    @State private var services: [ServiceUnit] = []
    @State private var stop: Set<String> = []
    @State private var onlyMe = true
    @State private var passwordsOff = true
    @State private var endSessions = true
    @State private var root = RootRunner()
    @State private var task: Task?
    @State private var preparing = false
    @State private var error: String?
    @State private var active: String? = nil
    @State private var summary: Lockdown.Summary?
    @State private var clearing = false

    struct Task: Identifiable { let id: String; let change: ConfigChange }

    private var storeKey: String { "lockdown.\(server.id.uuidString)" }

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let active {
                lockedDown(active)
            } else {
                plan
            }
        }
        .navigationTitle("Panic button")
        .sudoPassword(root, server: server)
        .task { await load() }
        .sheet(item: $task) { t in
            RootTaskSheet(server: server, title: "Lock down this server",
                          summary: "Saves the evidence first, then changes SSH and the firewall. If the app can't log in again within five minutes, everything is undone by itself.",
                          files: t.change.files, script: t.change.script(id: t.id), steps: RootTaskSheet.changeSteps,
                          confirm: "Lock down", destructive: true, guardID: t.id) { ok in
                if ok {
                    UserDefaults.standard.set(t.id, forKey: storeKey)
                    active = t.id
                    _Concurrency.Task { await loadSummary(t.id) }
                }
            }
        }
    }

    @ViewBuilder private var plan: some View {
        Section {
            Label("Use this when you think someone else is on your server. Deckhand saves the evidence, then shuts the doors — and can open them again with one tap.", systemImage: "light.beacon.max.fill")
                .font(.subheadline).foregroundStyle(.red)
        }
        Section {
            Label("Save the evidence first", systemImage: "archivebox").foregroundStyle(.secondary)
            Toggle(isOn: $onlyMe) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SSH only from this iPhone")
                    Text(myAddress.isEmpty ? String(localized: "Finding your address …") : String(localized: "Your address: \(myAddress)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!Lockdown.Plan(myAddress: myAddress).canRestrict)
            Toggle("Passwords and root login off", isOn: $passwordsOff)
            Toggle("End all other SSH sessions", isOn: $endSessions)
        } header: {
            Text("What happens")
        } footer: {
            Text("Evidence: who is logged in, recent logins, processes, network connections, files changed today, SSH keys, cron jobs and the SSH log, in a folder only root can read.")
        }
        if !services.isEmpty {
            Section {
                ForEach(services) { s in
                    Toggle(s.shortName, isOn: Binding(get: { stop.contains(s.name) }, set: { if $0 { stop.insert(s.name) } else { stop.remove(s.name) } }))
                }
            } header: {
                Text("Stop public services")
            } footer: {
                Text("Takes websites and databases offline until you give the all clear.")
            }
        }
        Section {
            Button(role: .destructive) { _Concurrency.Task { await start() } } label: {
                HStack { Label("Lock down now", systemImage: "lock.trianglebadge.exclamationmark.fill").font(.headline); Spacer(); if preparing { ProgressView() } }
            }
            .disabled(preparing || myAddress.isEmpty)
            .accessibilityIdentifier("panic.lock")
        } footer: {
            Text("Asks for Face ID, then your sudo password.")
        }
    }

    @ViewBuilder private func lockedDown(_ id: String) -> some View {
        Section {
            Label("This server is locked down", systemImage: "lock.shield.fill").font(.headline).foregroundStyle(.orange)
            if let s = summary {
                LabeledContent("Evidence files", value: "\(s.evidenceFiles)")
                LabeledContent("Other sessions ended", value: "\(s.endedSessions)")
                LabeledContent("Files changed in the last day", value: "\(s.changedFiles)")
                LabeledContent("SSH keys on the server", value: "\(s.authorizedKeys)")
                if !s.stopped.isEmpty { LabeledContent("Stopped", value: s.stopped.joined(separator: ", ")) }
            }
        } footer: {
            Text("Evidence is in \(Lockdown.evidenceDir(id: id)).")
        }
        Section {
            NavigationLink { KeysView() } label: { Label("Review SSH keys", systemImage: "key") }
            NavigationLink { ChangeHistoryView(server: server) } label: { Label("What changed recently", systemImage: "clock.arrow.circlepath") }
        } footer: {
            Text("Remove keys you don't recognise. Then look for anything you didn't change yourself.")
        }
        Section {
            Button { _Concurrency.Task { await allClear(id) } } label: {
                HStack { Label("All clear: undo the lockdown", systemImage: "lock.open"); Spacer(); if clearing { ProgressView() } }
            }
            .disabled(clearing)
            .accessibilityIdentifier("panic.allclear")
        } footer: {
            Text("Restores SSH and the firewall and starts the stopped services again. The evidence stays.")
        }
    }

    private func load() async {
        active = UserDefaults.standard.string(forKey: storeKey)
        do {
            let conn = try await connections.connection(for: server)
            myAddress = try await conn.run(Fail2ban.myAddressCommand, timeout: .seconds(10)).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let all = Services.parse(try await conn.run(Services.listCommand, timeout: .seconds(20)).stdout)
            services = all.filter { s in s.isRunning && Lockdown.stoppable.contains(s.shortName) }
            onlyMe = Lockdown.Plan(myAddress: myAddress).canRestrict
        } catch {
            self.error = error.localizedDescription
        }
        if let active { await loadSummary(active) }
    }

    private func start() async {
        var skipAuth = false
        #if DEBUG
        skipAuth = ProcessInfo.processInfo.environment["DECKHAND_SEED_SKIPAUTH"] == "1" // simulator UI tests: no Face ID
        #endif
        if !skipAuth {
            let ctx = LAContext()
            guard (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Lock down \(server.displayName)"))) == true else { return }
        }
        preparing = true
        defer { preparing = false }
        // The ports sshd really listens on (the dialed port can be forwarded).
        guard await root.run(SSHPort.inspectScript, on: server) else { error = root.lines.last ?? String(localized: "Couldn't read the SSH setup."); return }
        let ports = SSHPort.parse(root.lines.joined(separator: "\n")).ports
        let plan = Lockdown.Plan(myAddress: myAddress, sshPorts: ports.isEmpty ? [22] : ports, onlyMyAddress: onlyMe,
                                 passwordsOff: passwordsOff, endOtherSessions: endSessions, stopServices: Array(stop).sorted())
        let id = ConfigChange.makeID(title: "Lockdown")
        task = Task(id: id, change: Lockdown.change(plan, id: id))
    }

    private func loadSummary(_ id: String) async {
        if await root.run(Lockdown.summaryScript(id: id), on: server) {
            summary = Lockdown.parseSummary(root.lines.joined(separator: "\n"))
        }
    }

    private func allClear(_ id: String) async {
        clearing = true
        defer { clearing = false }
        if await root.run(Lockdown.allClearScript(id: id), on: server), root.lines.contains("@@allclear") {
            UserDefaults.standard.removeObject(forKey: storeKey)
            active = nil; summary = nil
        } else {
            error = root.lines.last ?? String(localized: "Couldn't undo the lockdown.")
        }
    }
}
