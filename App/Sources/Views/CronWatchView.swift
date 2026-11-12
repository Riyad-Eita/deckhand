import DeckhandCore
import SwiftUI

/// The user's cron jobs with heartbeats: watch a job to record every run and get a push when it fails or stops
/// running; unwatching puts the original line back.
struct CronWatchView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @Environment(AppSettings.self) private var settings
    @State private var status: CronWatch.Status?
    @State private var busy: String?
    @State private var error: String?
    @State private var timers: [CronEditor.Timer] = []
    @State private var editing: EditTarget?

    /// A new job (`line` nil) or an existing line to change.
    struct EditTarget: Identifiable { let line: String?; var id: String { line ?? "new" } }

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let status {
                Section {
                    if status.jobs.isEmpty {
                        Text("No cron jobs for \(server.username) yet.").foregroundStyle(.secondary)
                    }
                    ForEach(status.jobs) { job in
                        JobRow(job: job, watch: job.watchID.flatMap { status.watches[$0] }, busy: busy == job.id) {
                            Task { await toggle(job) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if job.watchID == nil { editing = EditTarget(line: job.line) }
                            else { error = String(localized: "Stop watching this job to change it.") }
                        }
                        .swipeActions {
                            if job.watchID == nil {
                                Button("Delete", role: .destructive) { Task { await perform(CronEditor.replaceCommand(job.line, with: nil)) } }
                            }
                        }
                    }
                } header: {
                    Text("Cron jobs")
                } footer: {
                    Text("Watched jobs run through a small wrapper that records each run. You get a push when a run fails or when a job hasn't run on time. Jobs of \(server.username) only.")
                }
                if !timers.isEmpty {
                    Section {
                        ForEach(timers) { TimerRow(timer: $0) }
                    } header: {
                        Text("systemd timers")
                    } footer: {
                        Text("Timers are managed by the system; Deckhand shows them read-only.")
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = EditTarget(line: nil) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New job")
                    .accessibilityIdentifier("cron.new")
            }
        }
        .sheet(item: $editing) { target in
            JobEditorSheet(line: target.line) { newLine in
                Task {
                    await perform(target.line.map { CronEditor.replaceCommand($0, with: newLine) } ?? CronEditor.addCommand(newLine))
                }
            }
        }
        .navigationTitle("Scheduled jobs")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func name(_ job: CronWatch.Job) -> String {
        let first = job.command.split(separator: " ").first.map { ($0 as NSString).lastPathComponent } ?? job.command
        return "\(first) (\(CronWatch.describe(job.schedule).lowercased()))"
    }

    private func toggle(_ job: CronWatch.Job) async {
        busy = job.id
        defer { busy = nil }
        if settings.ntfyTopicURL.isEmpty { settings.ntfyTopicURL = TaskNotifier.newTopicURL() }
        let command = job.watchID.map { CronWatch.unwatchCommand(id: $0) }
            ?? CronWatch.watchCommand(line: job.line, name: name(job), topic: settings.ntfyTopicURL)
        do {
            let conn = try await connections.connection(for: server)
            let out = try await conn.run(command, timeout: .seconds(30)).stdout
            if let f = out.split(separator: "\n").first(where: { $0.hasPrefix("@@failed") }) {
                error = switch f.dropFirst(9) {
                case "uses %": String(localized: "This job passes input with % — it can't be watched without changing it.")
                case "line changed": String(localized: "The crontab changed in the meantime. Pull to refresh and try again.")
                default: String(f.dropFirst(9))
                }
            } else { error = nil }
            await load()
        } catch { self.error = error.localizedDescription }
    }

    private func perform(_ command: String) async {
        do {
            let conn = try await connections.connection(for: server)
            let out = try await conn.run(command, timeout: .seconds(30)).stdout
            error = out.contains("@@failed line changed") ? String(localized: "The crontab changed in the meantime. Pull to refresh and try again.") : nil
            await load()
        } catch { self.error = error.localizedDescription }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            status = CronWatch.parseStatus(try await conn.run(CronWatch.statusCommand, timeout: .seconds(30)).stdout)
            timers = CronEditor.parseTimers((try? await conn.run(CronEditor.timersCommand, timeout: .seconds(60)).stdout) ?? "")
        } catch { self.error = error.localizedDescription }
    }
}

private struct JobRow: View {
    let job: CronWatch.Job
    let watch: CronWatch.Watch?
    let busy: Bool
    let toggle: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(CronWatch.describe(job.schedule))).font(.subheadline.weight(.medium))
                    Text(watch.map { _ in originalCommand } ?? job.command).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if busy { ProgressView() } else {
                    Button(watch == nil ? "Watch" : "Stop watching", action: toggle)
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityIdentifier(watch == nil ? "cron.watch" : "cron.unwatch")
                }
            }
            if let w = watch {
                status(w)
                if !w.runs.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(Array(w.runs.suffix(24).enumerated()), id: \.offset) { _, r in
                            RoundedRectangle(cornerRadius: 2).fill(r.exitCode == 0 ? Color.green : Color.red).frame(width: 7, height: 14)
                        }
                    }
                    .accessibilityHidden(true)
                }
                if !w.output.isEmpty {
                    DisclosureGroup("Last output", isExpanded: $expanded) {
                        Text(w.output.joined(separator: "\n")).font(Theme.monoSmall).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cron.job")
    }

    /// The watched line runs the wrapper; show the user's own command instead.
    private var originalCommand: String {
        watch.map { $0.originalCommand.isEmpty ? $0.name : $0.originalCommand } ?? job.command
    }

    @ViewBuilder private func status(_ w: CronWatch.Watch) -> some View {
        if let missing = w.missingSince {
            Label(String(localized: "Didn't run on time (noticed \(missing.formatted(.relative(presentation: .named))))"),
                  systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        } else if let r = w.last {
            Label(r.exitCode == 0
                  ? String(localized: "Last run \(r.start.formatted(.relative(presentation: .named))), \(r.seconds) s")
                  : String(localized: "Failed \(r.start.formatted(.relative(presentation: .named))) with exit code \(r.exitCode)"),
                  systemImage: r.exitCode == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.caption).foregroundStyle(r.exitCode == 0 ? .green : .red)
                .accessibilityIdentifier("cron.last")
        } else {
            Label("Watching — no run yet", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct TimerRow: View {
    let timer: CronEditor.Timer
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(timer.unit.replacingOccurrences(of: ".timer", with: "")).font(.subheadline.weight(.medium))
                Spacer()
                if let ok = timer.ok {
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(ok ? .green : .red)
                }
            }
            if !timer.description.isEmpty { Text(timer.description).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 12) {
                if !timer.calendar.isEmpty { Text(timer.calendar).font(Theme.monoSmall) }
                if let next = timer.next { Text("next \(next.formatted(.relative(presentation: .named)))") }
                if let last = timer.last { Text("last \(last.formatted(.relative(presentation: .named)))") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// New job or changed schedule/command, without cron syntax: frequency, time and days, with the cron line shown.
private struct JobEditorSheet: View {
    let line: String?
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var schedule = CronEditor.Schedule()
    @State private var command = ""
    @State private var time = Calendar.current.date(from: DateComponents(hour: 3, minute: 0)) ?? Date()

    private var valid: Bool {
        !command.trimmingCharacters(in: .whitespaces).isEmpty && CronEditor.isValidExpression(schedule.cron)
            && !(schedule.frequency == .weekly && schedule.weekdays.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Command", text: $command, axis: .vertical).font(Theme.mono).lineLimit(1...4)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("cron.command")
                } header: { Text("What") }
                Section {
                    Picker("Runs", selection: $schedule.frequency) {
                        ForEach(CronEditor.Frequency.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                    .accessibilityIdentifier("cron.frequency")
                    switch schedule.frequency {
                    case .minutes:
                        Stepper(String(localized: "Every \(schedule.everyMinutes) minutes"), value: $schedule.everyMinutes, in: 1...30)
                    case .hourly:
                        Stepper(String(format: String(localized: "At minute %02d"), schedule.minute), value: $schedule.minute, in: 0...59)
                    case .daily, .weekly, .monthly:
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        if schedule.frequency == .weekly {
                            HStack(spacing: 6) {
                                ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { d in
                                    let on = schedule.weekdays.contains(d)
                                    Button(Calendar.current.veryShortWeekdaySymbols[d]) {
                                        if on { schedule.weekdays.remove(d) } else { schedule.weekdays.insert(d) }
                                    }
                                    .buttonStyle(.bordered).tint(on ? Theme.accent : .secondary)
                                    .accessibilityIdentifier("cron.day.\(d)")
                                }
                            }
                        }
                        if schedule.frequency == .monthly {
                            Stepper(String(localized: "On day \(schedule.dayOfMonth)"), value: $schedule.dayOfMonth, in: 1...28)
                        }
                    case .custom:
                        TextField("0 3 * * 1", text: $schedule.expression).font(Theme.mono)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: {
                    Text("When")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(schedule.description)).accessibilityIdentifier("cron.preview")
                        Text(schedule.cron).font(Theme.monoSmall)
                        if !CronEditor.isValidExpression(schedule.cron) { Text("That isn't a valid cron expression.").foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle(line == nil ? String(localized: "New job") : String(localized: "Change job"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(CronEditor.line(schedule: schedule.cron, command: command.trimmingCharacters(in: .whitespaces))); dismiss() }
                        .disabled(!valid)
                        .accessibilityIdentifier("cron.save")
                }
            }
            .onChange(of: time) {
                let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                schedule.hour = c.hour ?? 3; schedule.minute = c.minute ?? 0
            }
            .onAppear {
                guard let line, let p = CronWatch.parseLine(line) else { return }
                schedule = CronEditor.Schedule.from(p.schedule)
                command = p.command.replacingOccurrences(of: "\\%", with: "%")
                time = Calendar.current.date(from: DateComponents(hour: schedule.hour, minute: schedule.minute)) ?? time
            }
        }
    }
}
