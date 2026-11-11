import DeckhandCore
import SwiftUI

/// Uptime checks for websites and APIs, run by the server itself; pushes when something goes down.
struct UptimeView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @Environment(AppSettings.self) private var settings
    @State private var status: Uptime.Status?
    @State private var error: String?
    @State private var adding = false
    @State private var busy = false
    @State private var incident: String?
    @State private var remedyFor: Uptime.Check?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let status {
                if !status.installed {
                    Section {
                        Label("Your server checks your sites every minute — also while this iPhone is off — and sends a push when one goes down or comes back.", systemImage: "waveform.path.ecg")
                            .font(.subheadline)
                        Button("Turn on uptime checks") { Task { await install() } }.disabled(busy)
                            .accessibilityIdentifier("uptime.install")
                    } footer: {
                        Text(settings.ntfyTopicURL.isEmpty
                             ? "Pushes go through ntfy; a private topic is created for you (Settings → Notifications)."
                             : "Pushes go to your ntfy topic from Settings → Notifications.")
                    }
                } else {
                    if !status.cron {
                        Text("This server has no cron, so checks only run when you tap Check now.").font(.footnote).foregroundStyle(.orange)
                    }
                    Section {
                        if status.checks.isEmpty { Text("No checks yet.").foregroundStyle(.secondary) }
                        ForEach(status.checks) { check in
                            CheckRow(check: check) { incident = check.id }
                                .swipeActions {
                                    Button("Delete") { Task { await run(Uptime.removeCommand(id: check.id)) } }.tint(.red)
                                    Button("Auto-fix") { remedyFor = check }.tint(Theme.accent)
                                }
                                .contextMenu {
                                    Button { remedyFor = check } label: { Label("Automatic fix…", systemImage: "wand.and.sparkles") }
                                }
                        }
                        Button { adding = true } label: { Label("Add a check", systemImage: "plus") }
                            .accessibilityIdentifier("uptime.add")
                    } footer: {
                        Text("Checked by your server via cron. Response times of the last 24 hours.")
                    }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Uptime")
        .toolbar {
            if status?.installed == true {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await run("FORCE=1 sh \"$HOME/.deckhand/uptime/run.sh\"") } } label: {
                        if busy { ProgressView() } else { Text("Check now") }
                    }
                    .disabled(busy)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $remedyFor) { check in
            RemedySheet(server: server, checkID: check.id, checkName: check.name, existing: check.remedy) { Task { await load() } }
        }
        .navigationDestination(item: $incident) { IncidentView(server: server, checkID: $0) }
        .sheet(isPresented: $adding) {
            AddCheckSheet { check in
                Task {
                    // Refreshes the runner too, so pushes carry the link back into the app.
                    await run(Uptime.installCommand(topic: settings.ntfyTopicURL, server: server.id))
                    await run(Uptime.addCommand(check))
                }
            }
        }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            status = Uptime.parse(try await conn.run(Uptime.statusCommand, timeout: .seconds(30)).stdout)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func install() async {
        if settings.ntfyTopicURL.isEmpty { settings.ntfyTopicURL = TaskNotifier.newTopicURL() }
        await run(Uptime.installCommand(topic: settings.ntfyTopicURL, server: server.id))
    }

    private func run(_ command: String) async {
        busy = true
        defer { busy = false }
        do {
            let conn = try await connections.connection(for: server)
            _ = try await conn.run(command, timeout: .seconds(120))
        } catch {
            self.error = error.localizedDescription
        }
        await load()
    }
}

private struct CheckRow: View {
    let check: Uptime.Check
    let investigate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(check.isUp == nil ? Color.secondary.opacity(0.4) : check.isUp! ? .green : .red).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.name).font(.body.weight(.medium))
                    Text(check.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let last = check.last {
                        Text(last.ok ? "\(last.milliseconds) ms" : (last.status == 0 ? String(localized: "No answer") : "HTTP \(last.status)"))
                            .font(.subheadline.monospacedDigit()).foregroundStyle(last.ok ? Color.primary : Color.red)
                    }
                    if let up = check.uptime {
                        Text("\((up * 100).formatted(.number.precision(.fractionLength(up == 1 || up == 0 ? 0 : 1)))) %").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let remedy = check.remedy {
                let today = remedy.runsToday
                Label(today.isEmpty ? String(localized: "Fixes itself when it fails")
                      : String(localized: "Fixed itself \(today.filter(\.fixed).count)× today"), systemImage: "wand.and.sparkles")
                    .font(.caption).foregroundStyle(Theme.accent)
            }
            if check.results.count > 1 { Sparkline(results: Array(check.results.suffix(60))).frame(height: 28) }
            if check.isUp == false {
                Button(action: investigate) { Label("Investigate with an agent", systemImage: "sparkle.magnifyingglass") }
                    .font(.footnote).buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Response times as a line; failed checks as red dots on the baseline.
private struct Sparkline: View {
    let results: [Uptime.Result]
    var body: some View {
        GeometryReader { g in
            let maxMs = Double(max(results.map(\.milliseconds).max() ?? 1, 1))
            let step = g.size.width / CGFloat(max(results.count - 1, 1))
            Path { p in
                for (i, r) in results.enumerated() where r.ok {
                    let pt = CGPoint(x: CGFloat(i) * step, y: g.size.height * (1 - CGFloat(Double(r.milliseconds) / maxMs) * 0.9))
                    if i == 0 || !results[i - 1].ok { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            ForEach(Array(results.enumerated()).filter { !$0.element.ok }, id: \.offset) { i, _ in
                Circle().fill(.red).frame(width: 4, height: 4).position(x: CGFloat(i) * step, y: g.size.height - 2)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct AddCheckSheet: View {
    let add: (Uptime.Check) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var every = 5
    @State private var expect = "200-399"
    @State private var keyword = ""

    private var check: Uptime.Check {
        Uptime.Check(name: name.isEmpty ? (URL(string: url)?.host ?? url) : name, url: url.trimmingCharacters(in: .whitespaces),
                     every: every, expect: expect.trimmingCharacters(in: .whitespaces), keyword: keyword)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/health", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("check.url")
                    TextField("Name (optional)", text: $name)
                }
                Section {
                    Picker("Every", selection: $every) {
                        Text("minute").tag(1); Text("5 minutes").tag(5); Text("15 minutes").tag(15); Text("hour").tag(60)
                    }
                    TextField("Expected status", text: $expect).keyboardType(.numbersAndPunctuation)
                    TextField("Page must contain (optional)", text: $keyword)
                } footer: {
                    Text("Expected status: a code like 200 or a range like 200-399.")
                }
            }
            .navigationTitle("Add a check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add(check); dismiss() }.disabled(!Uptime.isValid(check)).accessibilityIdentifier("check.save")
                }
            }
        }
    }
}
