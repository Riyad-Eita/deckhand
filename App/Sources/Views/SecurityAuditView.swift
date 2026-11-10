import DeckhandCore
import SwiftUI

/// A security score with a list of concrete fixes, worst first.
struct SecurityAuditView: View {
    let server: Server
    @State private var root = RootRunner()
    @State private var checks: [SecurityAudit.Check]?
    @State private var previousScore: Int?
    @State private var expanded: String?
    @State private var fixing: FixRun?
    @State private var installing: SecurityAudit.Check?
    @State private var investigatePrompt: String?

    struct FixRun: Identifiable {
        let id = UUID()
        let check: SecurityAudit.Check
        let change: ConfigChange
        let changeID: String
        let guarded: Bool
    }

    var body: some View {
        List {
            if let checks {
                Section {
                    ScoreHeader(score: SecurityAudit.score(checks), previous: previousScore, issues: checks.filter { $0.level != .good }.count)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    ForEach(checks) { check in
                        CheckRow(server: server, check: check, expanded: expanded == check.id) {
                            withAnimation(.snappy) { expanded = expanded == check.id ? nil : check.id }
                        } fix: { act(on: check) }
                    }
                } footer: {
                    Text("Fixes back up every file first and can be rolled back in the change history.")
                }
            } else if case .failed(let m) = root.phase {
                Text(m).foregroundStyle(.red).font(.footnote)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Checking the server…").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40).listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Security check-up")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await run() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(root.isRunning).accessibilityLabel("Check again")
            }
        }
        .task { if checks == nil { await run() } }
        .refreshable { await run() }
        .sudoPassword(root, server: server)
        .investigate(on: server, prompt: $investigatePrompt)
        .sheet(item: $fixing, onDismiss: { Task { await run() } }) { f in
            RootTaskSheet(
                server: server, title: LocalizedStringKey(f.change.title), summary: LocalizedStringKey(f.check.explanation),
                files: f.change.files, script: f.change.script(id: f.changeID), steps: RootTaskSheet.changeSteps,
                confirm: "Fix", guardID: f.guarded ? f.changeID : nil)
        }
        .sheet(item: $installing, onDismiss: { Task { await run() } }) { check in
            if case .run(let title, let script)? = check.fix {
                RootTaskSheet(
                    server: server, title: LocalizedStringKey(title),
                    summary: "Installs all waiting updates with the package manager. Services may restart briefly. This can't be rolled back.",
                    files: [], script: script, steps: [("refresh", "Refresh the package lists"), ("install", "Install the updates")],
                    confirm: "Install")
            }
        }
    }

    private func run() async {
        if let checks { previousScore = SecurityAudit.score(checks) }
        guard await root.run(SecurityAudit.script, on: server) else { return }
        let facts = SecurityAudit.parse(root.lines.joined(separator: "\n"))
        let context = SecurityAudit.Context(loginUser: server.username, usesKey: server.authKind == .key)
        withAnimation(.snappy) { checks = SecurityAudit.checks(facts, context: context) }
    }

    private func act(on check: SecurityAudit.Check) {
        switch check.fix {
        case .change(let change, let guarded)?:
            fixing = FixRun(check: check, change: change, changeID: ConfigChange.makeID(title: change.title), guarded: guarded)
        case .run?:
            installing = check
        case .agent(let prompt)?:
            investigatePrompt = prompt
        case .sshPort?, nil:
            break
        }
    }
}

private struct ScoreHeader: View {
    let score: Int
    let previous: Int?
    let issues: Int

    var color: Color { score >= 80 ? .green : score >= 50 ? .orange : .red }

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().stroke(color.opacity(0.15), lineWidth: 10)
                Circle().trim(from: 0, to: CGFloat(score) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(score)").font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: 92, height: 92)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Score \(score) of 100"))
            VStack(alignment: .leading, spacing: 4) {
                Text(score >= 80 ? "Well protected" : score >= 50 ? "Room to improve" : "Needs attention").font(.title3.weight(.semibold))
                Text(issues == 0 ? "Nothing to fix." : (issues == 1 ? "1 thing to look at" : "\(issues) things to look at"))
                    .font(.subheadline).foregroundStyle(.secondary)
                if let previous, previous != score {
                    Text(score > previous ? "Up from \(previous)" : "Down from \(previous)")
                        .font(.caption.weight(.semibold)).foregroundStyle(score > previous ? .green : .orange)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline))
    }
}

private struct CheckRow: View {
    let server: Server
    let check: SecurityAudit.Check
    let expanded: Bool
    let toggle: () -> Void
    let fix: () -> Void

    var color: Color { check.level == .good ? .green : check.level == .warn ? .orange : .red }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    Image(systemName: check.level == .good ? "checkmark.circle.fill" : check.level == .warn ? "exclamationmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(color).font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(check.title)).foregroundStyle(.primary)
                        Text(check.detail).font(.caption).foregroundStyle(.secondary).lineLimit(expanded ? nil : 1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("check.\(check.id)")
            if expanded {
                Text(LocalizedStringKey(check.explanation)).font(.subheadline).foregroundStyle(.secondary)
                if let blocked = check.fixBlocked {
                    Label(LocalizedStringKey(blocked), systemImage: "lock").font(.footnote).foregroundStyle(.orange)
                }
                fixButton
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var fixButton: some View {
        switch check.fix {
        case .change?, .run?:
            Button(action: fix) { Label(check.fix.map(label) ?? "Fix", systemImage: "wrench.and.screwdriver") }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(check.fixBlocked != nil)
                .accessibilityIdentifier("fix.\(check.id)")
        case .agent?:
            Button(action: fix) { Label("Fix with an agent", systemImage: "sparkles") }
                .buttonStyle(.bordered).controlSize(.small)
        case .sshPort?:
            NavigationLink { SSHPortView(server: server) } label: { Label("Change the SSH port", systemImage: "door.left.hand.closed") }
                .buttonStyle(.bordered).controlSize(.small)
        case nil:
            EmptyView()
        }
    }

    private func label(_ fix: SecurityAudit.Fix) -> LocalizedStringKey {
        if case .run = fix { return "Install updates" }
        return "Fix"
    }
}
