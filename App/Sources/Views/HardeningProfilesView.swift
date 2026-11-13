import DeckhandCore
import DeckhandSSH
import SwiftData
import SwiftUI

/// A hardening preset for one or more servers: pick the profile, see per server what it changes (and what the
/// firewall closes), then apply it — server by server, each risky step confirmed by a fresh login or rolled back.
struct HardeningProfilesView: View {
    var preselected: Server?
    @Environment(Connections.self) private var connections
    @Query(sort: \Server.name) private var servers: [Server]
    @State private var profile: HardeningProfile = .webServer
    @State private var clients = ""
    @State private var chosen: Set<UUID> = []
    @State private var root = RootRunner()
    @State private var follow = RootRunner()
    @State private var current: Server?
    @State private var plans: [UUID: HardeningPlan.Plan] = [:]
    @State private var failures: [UUID: String] = [:]
    @State private var progress: [UUID: [String: StepState]] = [:]
    @State private var phase: Phase = .choosing
    @State private var confirm = false
    @FocusState private var editingClients: Bool

    enum Phase { case choosing, previewing, previewed, applying, done }
    enum StepState: Equatable { case running, done, failed(String) }

    private var selected: [Server] { servers.filter { chosen.contains($0.id) } }
    private var clientList: [String] {
        clients.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
    }
    private var invalidClients: [String] { clientList.filter { !HardeningPlan.isValidSource($0) } }
    private var changeCount: Int { selected.compactMap { plans[$0.id] }.reduce(0) { $0 + $1.changes.count } }

    var body: some View {
        List {
            Section {
                ForEach(HardeningProfile.allCases) { p in
                    Button { profile = p; resetPreview() } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: p.symbol).font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title).font(.body.weight(.medium))
                                Text(p.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if profile == p { Image(systemName: "checkmark").foregroundStyle(Theme.accent).font(.body.weight(.semibold)) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.\(p.rawValue)")
                }
                if profile == .database {
                    TextField("App servers allowed to reach the database (IPs)", text: $clients, axis: .vertical)
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
                        .focused($editingClients)
                        .onChange(of: clients) { resetPreview() }
                        .accessibilityIdentifier("profile.clients")
                    if !invalidClients.isEmpty {
                        Text("Not an IP address or range: \(invalidClients.joined(separator: ", "))").font(.caption).foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Profile")
            }

            Section("Servers") {
                ForEach(servers) { s in
                    Button {
                        if chosen.contains(s.id) { chosen.remove(s.id) } else { chosen.insert(s.id) }
                        resetPreview()
                    } label: {
                        HStack {
                            Image(systemName: chosen.contains(s.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(chosen.contains(s.id) ? Theme.accent : .secondary)
                            Text(s.displayName)
                            Spacer()
                            serverBadge(s)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(phase == .previewing || phase == .applying)
                    .accessibilityIdentifier("profile.server.\(s.displayName)")
                }
            }

            if phase == .choosing || phase == .previewing {
                Section {
                    Button { editingClients = false; Task { await preview() } } label: {
                        HStack { Text("Preview the changes").font(.headline); Spacer(); if phase == .previewing { ProgressView() } }
                    }
                    .disabled(chosen.isEmpty || phase == .previewing || !invalidClients.isEmpty)
                    .accessibilityIdentifier("profile.preview")
                } footer: {
                    Text("Reads each server's settings as root first; nothing changes until you apply.")
                }
            }

            ForEach(selected) { s in
                if let plan = plans[s.id] { planSection(plan, server: s) }
                else if let f = failures[s.id] { Section(s.displayName) { ProblemView(message: f, compact: true) } }
            }

            if phase == .previewed && changeCount > 0 {
                Section {
                    Button { confirm = true } label: {
                        Text(selected.count == 1 ? String(localized: "Apply \(changeCount) changes")
                             : String(localized: "Apply \(changeCount) changes to \(selected.count) servers")).font(.headline)
                    }
                    .accessibilityIdentifier("profile.apply")
                } footer: {
                    Text("Firewall and SSH changes are confirmed by a fresh login and undone by themselves if it fails. Every change can be rolled back from Change history.")
                }
            } else if phase == .previewed {
                Section { Label("Nothing to change — these servers already match the profile.", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
            }
            if phase == .done {
                Section { Label("Done. Open the security check-up to see the new score.", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    .accessibilityIdentifier("profile.done")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Hardening profiles")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Sudo password", isPresented: $root.passwordPrompt) {
            SecureField("Password", text: $root.password)
            Button("Continue") { root.submitPassword() }
            Button("Cancel", role: .cancel) { root.cancel() }
        } message: {
            Text("for \(current?.username ?? "") on \(current?.displayName ?? ""). Deckhand keeps it in memory until you quit the app.")
        }
        .alert("Sudo password", isPresented: $follow.passwordPrompt) {
            SecureField("Password", text: $follow.password)
            Button("Continue") { follow.submitPassword() }
            Button("Cancel", role: .cancel) { follow.cancel() }
        }
        .confirmationDialog(String(localized: "Apply “\(profile.title)”?"), isPresented: $confirm, titleVisibility: .visible) {
            Button("Apply") { Task { await apply() } }
        } message: {
            Text("\(changeCount) changes on \(selected.map(\.displayName).joined(separator: ", ")).")
        }
        .interactiveDismissDisabled(phase == .applying)
        .onAppear { if let preselected, chosen.isEmpty { chosen = [preselected.id] } }
    }

    @ViewBuilder private func serverBadge(_ s: Server) -> some View {
        if let steps = progress[s.id] {
            if steps.values.contains(where: { if case .failed = $0 { true } else { false } }) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if steps.values.contains(.running) {
                ProgressView()
            } else if phase == .done || !steps.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else if current?.id == s.id && phase == .previewing {
            ProgressView()
        }
    }

    private func planSection(_ plan: HardeningPlan.Plan, server s: Server) -> some View {
        Section {
            ForEach(plan.items) { item in
                HStack(alignment: .top, spacing: 10) {
                    icon(for: item, state: progress[s.id]?[item.id])
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.medium))
                        Text(item.detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if case .notPossible(let why) = item.state { Text(why).font(.caption).foregroundStyle(.orange) }
                        if case .failed(let why)? = progress[s.id]?[item.id] { Text(why).font(.caption).foregroundStyle(.red) }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("profile.item.\(s.displayName).\(item.id)")
            }
            ForEach(plan.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text(s.displayName)
        } footer: {
            if !plan.closes.isEmpty {
                Text("The firewall will block port \(plan.closes.map(String.init).joined(separator: ", ")) from the internet. Services on it keep running for the server itself.")
            }
        }
    }

    @ViewBuilder private func icon(for item: HardeningPlan.Item, state: StepState?) -> some View {
        switch (state, item.state) {
        case (.running?, _): ProgressView().frame(width: 20)
        case (.done?, _): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 20)
        case (.failed?, _): Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.orange).frame(width: 20)
        case (nil, .change): Image(systemName: "pencil.circle").foregroundStyle(Theme.accent).frame(width: 20)
        case (nil, .alreadyFine): Image(systemName: "checkmark.circle").foregroundStyle(.green).frame(width: 20)
        case (nil, .notPossible): Image(systemName: "minus.circle").foregroundStyle(.secondary).frame(width: 20)
        }
    }

    // MARK: - Actions

    private func resetPreview() {
        guard phase != .applying, phase != .previewing else { return }
        plans = [:]; failures = [:]; progress = [:]; phase = .choosing
    }

    private func preview() async {
        phase = .previewing
        plans = [:]; failures = [:]
        for s in selected {
            current = s
            if await root.run(SecurityAudit.script, on: s) {
                let facts = SecurityAudit.parse(root.lines.joined(separator: "\n"))
                let context = SecurityAudit.Context(loginUser: s.username, usesKey: s.authKind == .key)
                plans[s.id] = HardeningPlan.plan(profile, facts: facts, context: context, databaseClients: clientList)
            } else {
                failures[s.id] = root.lines.last(where: { !$0.hasPrefix("@@") }) ?? String(localized: "Couldn't read the server's settings.")
            }
        }
        current = nil
        phase = .previewed
    }

    private func apply() async {
        phase = .applying
        for s in selected {
            guard let plan = plans[s.id] else { continue }
            current = s
            progress[s.id] = [:]
            for item in plan.items {
                guard case .change(let change, let guarded) = item.state else { continue }
                progress[s.id]?[item.id] = .running
                progress[s.id]?[item.id] = guarded ? await applyGuarded(change, on: s) : await applyPlain(change, on: s)
            }
        }
        current = nil
        phase = .done
    }

    private func applyPlain(_ change: ConfigChange, on s: Server) async -> StepState {
        await root.run(change.script(id: ConfigChange.makeID(title: change.title)), on: s)
            ? .done : .failed(String(localized: "Undone automatically (\(root.failedStep ?? "error"))."))
    }

    /// Applies a change that could lock us out, logs in afresh and only then keeps it.
    private func applyGuarded(_ change: ConfigChange, on s: Server) async -> StepState {
        let cid = ConfigChange.makeID(title: change.title)
        guard await root.run(change.script(id: cid), on: s) else {
            return .failed(String(localized: "Undone automatically (\(root.failedStep ?? "error"))."))
        }
        do {
            let fresh = try await connections.testLogin(s, port: s.port)
            guard await follow.run(ConfigChange.confirmScript(id: cid), on: s, connection: fresh) else { throw CLIError("confirm") }
            await connections.adopt(fresh, for: s, port: s.port)
            return .done
        } catch {
            await follow.run(ConfigChange.rollbackScript(id: cid), on: s)
            return .failed(String(localized: "A fresh login failed, so this was rolled back."))
        }
    }
}
