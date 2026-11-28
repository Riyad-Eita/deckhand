import DeckhandCore
import DeckhandSSH
import SwiftUI

/// GitHub Actions through the server's `gh`: pick a repository, see its runs, open one, start a workflow.
struct ActionsView: View {
    let server: Server
    @AppStorage("actions.repo") private var repo = ""
    @State private var repos: [String]?
    @State private var runs: [ActionsRuns.Run]?
    @State private var error: String?
    @State private var starting = false
    @State private var noGH = false

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if noGH {
                Section {
                    Text("Connect GitHub first: Tools → Connect GitHub signs the server's GitHub CLI in.").foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Repository", selection: $repo) {
                    if repo.isEmpty { Text("Choose…").tag("") }
                    ForEach(repos ?? (repo.isEmpty ? [] : [repo]), id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("actions.repo")
            }
            if !repo.isEmpty {
                Section("Runs") {
                    if let runs {
                        if runs.isEmpty { Text("No runs yet.").foregroundStyle(.secondary) }
                        ForEach(runs) { r in
                            NavigationLink { ActionRunView(server: server, repo: repo, run: r) } label: { RunRow(run: r) }
                                .accessibilityIdentifier("actions.run.\(r.id)")
                        }
                    } else {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                }
            }
        }
        .navigationTitle("GitHub Actions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { starting = true } label: { Image(systemName: "play.fill") }
                    .disabled(repo.isEmpty)
                    .accessibilityLabel("Start a workflow")
                    .accessibilityIdentifier("actions.start")
            }
        }
        .refreshable { await loadRuns() }
        .task { await loadRepos(); await loadRuns() }
        .onChange(of: repo) { runs = nil; Task { await loadRuns() } }
        .appSheet(isPresented: $starting) { StartWorkflowSheet(server: server, repo: repo) { Task { try? await Task.sleep(for: .seconds(3)); await loadRuns() } } }
    }

    private func run(_ cmd: String, timeout: Int = 60) async throws -> String {
        try await Connections.shared.connection(for: server).run(cmd, timeout: .seconds(timeout)).stdout
    }

    private func loadRepos() async {
        #if DEBUG
        if let seed = ProcessInfo.processInfo.environment["DECKHAND_SEED_ACTIONS_REPOS"] {
            repos = seed.split(separator: ",").map(String.init); if repo.isEmpty { repo = repos?.first ?? "" }; return
        }
        #endif
        do {
            let out = try await run(ActionsRuns.reposCommand)
            if let list = ActionsRuns.parseRepos(out) { repos = list; if repo.isEmpty { repo = list.first ?? "" } } else { noGH = true }
        } catch { self.error = error.localizedDescription }
    }

    private func loadRuns() async {
        guard !repo.isEmpty else { return }
        #if DEBUG
        if let seed = ProcessInfo.processInfo.environment["DECKHAND_SEED_ACTIONS_RUNS"] { runs = ActionsRuns.parseRuns(seed) ?? []; return }
        #endif
        guard let cmd = ActionsRuns.runsCommand(repo: repo) else { return }
        do {
            let out = try await run(cmd)
            if let r = ActionsRuns.parseRuns(out) { runs = r; error = nil } else { runs = []; error = out.trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch { self.error = error.localizedDescription }
    }
}

private struct RunRow: View {
    let run: ActionsRuns.Run
    var body: some View {
        HStack(spacing: 10) {
            StateIcon(state: run.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title).font(.subheadline.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(run.workflow)
                    Text("· \(run.branch)").font(Theme.monoSmall)
                    if let c = run.created { Text("· \(c, format: .relative(presentation: .named))") }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct StateIcon: View {
    let state: ActionsRuns.State
    var body: some View {
        Group {
            switch state {
            case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
            case .running: ProgressView().controlSize(.small)
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .cancelled: Image(systemName: "slash.circle").foregroundStyle(.secondary)
            case .skipped, .other: Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
        }
        .frame(width: 22)
        .accessibilityLabel(state.rawValue)
    }
}

/// One run: its jobs and failed steps, the useful part of the log, re-run, and a push when it ends.
struct ActionRunView: View {
    let server: Server
    let repo: String
    let run: ActionsRuns.Run
    @State private var detail: ActionsRuns.Detail?
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    private var topic: String { AppSettings.shared.ntfyTopicURL }

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let notice { Label(notice, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary) }
            Section {
                HStack { StateIcon(state: run.state); Text(run.title).font(.headline) }
                LabeledContent("Workflow", value: run.workflow)
                LabeledContent("Branch") { Text(run.branch).font(Theme.monoSmall) }
                LabeledContent("Trigger", value: run.event)
                if let url = URL(string: run.url) { Link("Open on GitHub", destination: url) }
            }
            if let d = detail {
                Section("Jobs") {
                    ForEach(d.jobs) { j in
                        HStack(alignment: .top) {
                            StateIcon(state: j.state)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(j.name)
                                ForEach(j.failedSteps, id: \.self) { s in Text("✗ \(s)").font(.caption).foregroundStyle(.red) }
                            }
                        }
                    }
                }
                if !d.log.isEmpty {
                    Section("What failed") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(d.log).font(Theme.monoSmall).textSelection(.enabled)
                        }
                        .accessibilityIdentifier("actions.log")
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
            Section {
                if run.state == .failure || run.state == .cancelled {
                    Button { Task { await rerun() } } label: { Label("Re-run failed jobs", systemImage: "arrow.clockwise") }
                        .disabled(busy)
                        .accessibilityIdentifier("actions.rerun")
                }
                if !run.state.isDone {
                    Button { Task { await watch() } } label: { Label("Push me when it ends", systemImage: "bell") }
                        .disabled(busy || topic.isEmpty)
                        .accessibilityIdentifier("actions.watch")
                    if topic.isEmpty {
                        Text("Set up push notifications in Settings first; the server sends them while your phone sleeps.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Run")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func shell(_ cmd: String, timeout: Int = 90) async throws -> String {
        try await Connections.shared.connection(for: server).run(cmd, timeout: .seconds(timeout)).stdout
    }

    private func load() async {
        #if DEBUG
        if let seed = ProcessInfo.processInfo.environment["DECKHAND_SEED_ACTIONS_DETAIL"] {
            detail = ActionsRuns.parseDetail(seed.replacingOccurrences(of: "|", with: "\n").replacingOccurrences(of: "~", with: "\t")); return
        }
        #endif
        guard let cmd = ActionsRuns.detailCommand(repo: repo, run: run.id) else { return }
        do {
            let out = try await shell(cmd)
            if let d = ActionsRuns.parseDetail(out) { detail = d; error = nil } else { error = out.split(separator: "\n").first.map(String.init) }
        } catch { self.error = error.localizedDescription }
    }

    private func rerun() async {
        guard let cmd = ActionsRuns.rerunCommand(repo: repo, run: run.id) else { return }
        busy = true; defer { busy = false }
        do {
            let out = try await shell(cmd)
            if out.contains("@@ok") { notice = String(localized: "The failed jobs run again.") } else { error = out.trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch { self.error = error.localizedDescription }
    }

    private func watch() async {
        guard let cmd = ActionsRuns.watchCommand(repo: repo, run: run.id, title: run.title, topicURL: topic, onlyFailures: false) else { return }
        busy = true; defer { busy = false }
        do {
            let out = try await shell(cmd, timeout: 20)
            if out.contains("@@ok") { notice = String(localized: "The server watches this run and pushes when it ends.") } else { error = out }
        } catch { self.error = error.localizedDescription }
    }
}

/// Starts a workflow that has a manual trigger, on a branch.
private struct StartWorkflowSheet: View {
    let server: Server
    let repo: String
    let started: () -> Void
    @State private var workflows: [ActionsRuns.Workflow]?
    @State private var chosen: Int?
    @State private var ref = "main"
    @State private var error: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let error { ProblemView(message: error, compact: true) }
                if let workflows {
                    let manual = workflows.filter(\.dispatchable)
                    Section {
                        if manual.isEmpty {
                            Text("No workflow here can be started by hand. Add `workflow_dispatch:` to a workflow's `on:` to allow it.").foregroundStyle(.secondary)
                        }
                        Picker("Workflow", selection: $chosen) {
                            Text("Choose…").tag(Int?.none)
                            ForEach(manual) { Text($0.name).tag(Int?.some($0.id)) }
                        }
                        TextField("Branch", text: $ref).font(Theme.mono).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle("Start a workflow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { Task { await start() } }.disabled(chosen == nil || ref.isEmpty || busy)
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        guard let cmd = ActionsRuns.workflowsCommand(repo: repo) else { return }
        do { workflows = ActionsRuns.parseWorkflows(try await Connections.shared.connection(for: server).run(cmd, timeout: .seconds(90)).stdout) }
        catch { self.error = error.localizedDescription; workflows = [] }
    }

    private func start() async {
        guard let id = chosen, let cmd = ActionsRuns.dispatchCommand(repo: repo, workflow: id, ref: ref) else { return }
        busy = true; defer { busy = false }
        do {
            let out = try await Connections.shared.connection(for: server).run(cmd, timeout: .seconds(60)).stdout
            if out.contains("@@ok") { started(); dismiss() } else { error = out.trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch { self.error = error.localizedDescription }
    }
}
