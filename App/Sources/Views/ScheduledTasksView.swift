import DeckhandCore
import SwiftUI

/// Recurring Claude Code / Codex tasks on one server ("every Monday: install security updates"). They run from the
/// server's crontab, so the phone can be off; every run shows up under Background tasks and can push when it ends.
struct ScheduledTasksView: View {
    let server: Server
    private var connections: Connections { .shared }
    @State private var entries: [AgentSchedules.Entry]?
    @State private var error: String?
    @State private var busy: String?
    @State private var editing: EditTarget?
    @State private var confirmDelete: AgentSchedules.Entry?

    struct EditTarget: Identifiable {
        var schedule: AgentSchedule?
        var id: String { schedule?.id ?? "new" }
    }

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let entries {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("No scheduled tasks", systemImage: "calendar.badge.clock")
                    } description: {
                        Text("Give Claude Code or Codex a job that comes back: \"Every Monday at 6:00, install security updates and restart what needs it.\"")
                    } actions: {
                        Button("New Scheduled Task") { editing = EditTarget() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("schedules.empty.new")
                    }
                } else {
                    Section {
                        ForEach(entries) { entry in
                            ScheduleRow(entry: entry, busy: busy == entry.id)
                                .contentShape(Rectangle())
                                .onTapGesture { editing = EditTarget(schedule: entry.schedule) }
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", role: .destructive) { confirmDelete = entry }
                                }
                                .swipeActions(edge: .leading) {
                                    Button(entry.schedule.paused ? "Resume" : "Pause") { Task { await togglePause(entry) } }
                                        .tint(entry.schedule.paused ? .green : .orange)
                                }
                                .contextMenu {
                                    Button { Task { await runNow(entry) } } label: { Label("Run Now", systemImage: "play") }
                                    Button { Task { await togglePause(entry) } } label: {
                                        Label(entry.schedule.paused ? "Resume" : "Pause", systemImage: entry.schedule.paused ? "play.circle" : "pause.circle")
                                    }
                                    Button { editing = EditTarget(schedule: entry.schedule) } label: { Label("Edit", systemImage: "pencil") }
                                    Button(role: .destructive) { confirmDelete = entry } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    } footer: {
                        Text("Runs start from this server's crontab, also while your phone is off. Each run uses your house rules and the access you chose, waits out usage limits, and is listed under Background tasks.")
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Scheduled Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = EditTarget() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New Scheduled Task")
                    .accessibilityIdentifier("schedules.new")
            }
            ToolbarItem(placement: .secondaryAction) {
                NavigationLink { BackgroundTasksView(server: server) } label: { Label("Background Tasks", systemImage: "moon.stars") }
            }
        }
        .appSheet(item: $editing) { target in
            ScheduleEditorSheet(server: server, original: target.schedule) { saved in
                Task { await save(saved) }
            }
        }
        .confirmationDialog("Delete \(confirmDelete?.schedule.name ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Scheduled Task", role: .destructive) { if let e = confirmDelete { Task { await delete(e) } } }
        } message: {
            Text("It won't run again. Its earlier runs stay under Background tasks.")
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            entries = AgentSchedules.parseList(try await conn.run(AgentSchedules.listCommand, timeout: .seconds(30)).stdout)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func perform(_ id: String, _ command: String) async -> String? {
        busy = id
        defer { busy = nil }
        do {
            let conn = try await connections.connection(for: server)
            let out = try await conn.run(command, timeout: .seconds(30)).stdout
            error = out.contains("@@failed") ? String(localized: "The server didn't accept the change.") : nil
            return out
        } catch { self.error = error.localizedDescription; return nil }
    }

    private func save(_ s: AgentSchedule) async {
        _ = await perform(s.id, AgentSchedules.saveCommand(s))
        await load()
    }

    private func togglePause(_ e: AgentSchedules.Entry) async {
        var s = e.schedule
        s.paused.toggle()
        await save(s)
    }

    private func runNow(_ e: AgentSchedules.Entry) async {
        TaskNotifier.shared.requestPermission()
        if let out = await perform(e.id, AgentSchedules.runNowCommand(id: e.id)), out.contains("@@skipped") {
            error = String(localized: "The last run of \(e.schedule.name) is still going.")
        }
        await load()
    }

    private func delete(_ e: AgentSchedules.Entry) async {
        _ = await perform(e.id, AgentSchedules.deleteCommand(id: e.id))
        await load()
    }
}

private struct ScheduleRow: View {
    let entry: AgentSchedules.Entry
    let busy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BrandIcon(brand: entry.schedule.cli == .codex ? .codex : .claude, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.schedule.name).font(.body.weight(.semibold)).lineLimit(2)
                Label {
                    Text(LocalizedStringKey(entry.schedule.when))
                } icon: {
                    Image(systemName: entry.schedule.paused ? "pause.circle" : "calendar.badge.clock")
                }
                .font(.subheadline).foregroundStyle(entry.schedule.paused ? .orange : .secondary)
                .accessibilityIdentifier("schedule.when")
                lastRun
                if entry.cron == .missing {
                    Label("Not in the crontab anymore. Open it and save to put it back.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            if busy { ProgressView() }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("schedule.row")
    }

    /// A missing CLI is the most common first failure; say so plainly.
    private func explain(_ reason: String) -> String {
        let cli = entry.schedule.cli
        if reason.contains("\(cli.executable): command not found") || reason.contains("\(cli.executable): not found") {
            return String(localized: "\(cli.displayName) isn't installed for this user on the server. Install it under Server Tools, then run again.")
        }
        return reason
    }

    @ViewBuilder private var lastRun: some View {
        if let last = entry.last {
            switch last.status {
            case .running:
                Label("Running now", systemImage: "circle.dotted").font(.caption).foregroundStyle(Theme.accent)
            case .waiting(let until):
                Label("Waiting for the usage limit until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.orange)
            case .ended(let code):
                let when = (last.started ?? .now).formatted(.relative(presentation: .named))
                if code == 0 {
                    Label("Last run \(when): done", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                        .accessibilityIdentifier("schedule.lastOK")
                } else if code == 143 {
                    Label("Last run \(when): stopped", systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Last run \(when) didn't finish", systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                        if let reason = last.reason {
                            Text(explain(reason)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                .accessibilityIdentifier("schedule.reason")
                        }
                    }
                }
            }
        } else {
            Text("Hasn't run yet").font(.caption).foregroundStyle(.secondary)
        }
        if let skipped = entry.skipped {
            Text("Skipped \(skipped.formatted(.relative(presentation: .named))): the run before was still going")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// New or changed scheduled task: what to do, with which engine and access, and when — in plain words.
struct ScheduleEditorSheet: View {
    let server: Server
    let original: AgentSchedule?
    var prefill: (name: String, prompt: String, cli: ServerCLI, directory: String)?
    let save: (AgentSchedule) -> Void

    private var settings: AppSettings { .shared }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var prompt = ""
    @State private var cli: ServerCLI = .claudeCode
    @State private var directory = "~"
    @State private var access: CLIAccess = .readOnly
    @State private var schedule = CronEditor.Schedule()
    @State private var notify = true
    @State private var loaded = false

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ScheduleSection.isValid(schedule)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Weekly security updates"))
                        .accessibilityIdentifier("schedule.name")
                    TextField("Task", text: $prompt, prompt: Text("Install security updates and restart the services that need it. Tell me what changed."), axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("schedule.prompt")
                } header: {
                    Text("What")
                }
                Section {
                    Picker("Agent", selection: $cli) {
                        ForEach(ServerCLI.allCases) { Text($0.displayName).tag($0) }
                    }
                    .accessibilityIdentifier("schedule.agent")
                    TextField("Folder", text: $directory).font(Theme.mono)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Access", selection: $access) {
                        ForEach(CLIAccess.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                    .accessibilityIdentifier("schedule.access")
                } header: {
                    Text("How")
                } footer: {
                    Text(accessFooter)
                }
                ScheduleSection(schedule: $schedule, idPrefix: "schedule")
                Section {
                    Toggle("Push when a run ends", isOn: $notify)
                }
            }
            .navigationTitle(original == nil ? String(localized: "New Scheduled Task") : String(localized: "Scheduled Task"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(build()); dismiss() }
                        .disabled(!valid)
                        .accessibilityIdentifier("schedule.save")
                }
            }
            .onAppear(perform: load)
        }
    }

    private var accessFooter: String {
        switch access {
        case .readOnly: String(localized: "Read only: it can look around and report, but not change anything. Nobody is there to approve, so start here.")
        case .edit: String(localized: "It may change files in the folder; commands that aren't allowed by your house rules are refused.")
        case .full: String(localized: "Full access without asking. Your house rules still block what they forbid.")
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let s = original {
            name = s.name; prompt = s.prompt; cli = s.cli; directory = s.directory; access = s.access
            schedule = CronEditor.Schedule.from(s.cron); notify = s.notifyTopic != nil
        } else {
            schedule.frequency = .weekly; schedule.hour = 6; schedule.minute = 0; schedule.weekdays = [1]
            if let p = prefill { name = p.name; prompt = p.prompt; cli = p.cli; directory = p.directory }
        }
    }

    private func build() -> AgentSchedule {
        if notify, settings.ntfyTopicURL.isEmpty { settings.ntfyTopicURL = TaskNotifier.newTopicURL() }
        var options = settings.cliOptions(for: cli)
        options.maxBudgetUSD = HouseRulesStore.rules(for: server)?.maxSpendUSD
        var s = AgentSchedule(
            id: original?.id ?? AgentSchedules.newID(), name: name.trimmingCharacters(in: .whitespaces),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), cli: cli,
            directory: directory.trimmingCharacters(in: .whitespaces).isEmpty ? "~" : directory.trimmingCharacters(in: .whitespaces),
            access: access, cron: schedule.cron, paused: original?.paused ?? false, options: options,
            notifyTopic: notify ? settings.ntfyTopicURL : nil, created: original?.created ?? Date())
        if original != nil, s.cli == original?.cli { s.model = original?.model ?? s.model; s.effort = original?.effort ?? s.effort }
        return s
    }
}
