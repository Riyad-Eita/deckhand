import DeckhandCore
import SwiftData
import SwiftUI

/// A failing uptime check: what the server looks like right now, then an agent that diagnoses it read-only and
/// suggests a fix the chat can apply with one tap.
struct IncidentView: View {
    let server: Server
    let checkID: String
    @Environment(Connections.self) private var connections
    @Environment(\.modelContext) private var context
    @State private var check: Uptime.Check?
    @State private var evidence: [Incident.Evidence]?
    @State private var error: String?
    @State private var thread: ChatThread?
    @State private var signingIn: ServerCLI?
    @State private var showingSettings = false

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let check {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: check.isUp == false ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.title2).foregroundStyle(check.isUp == false ? .red : .green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.name).font(.headline)
                            Text(check.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if let last = check.last {
                        LabeledContent("Last result", value: last.ok ? String(localized: "Up, \(last.milliseconds) ms")
                                       : last.status == 0 ? String(localized: "No answer") : "HTTP \(last.status)")
                    }
                    if let since = check.downSince {
                        LabeledContent("Down since") { Text(since, format: .relative(presentation: .named)) }
                    }
                }
                Section {
                    if let evidence {
                        if evidence.isEmpty { Text("Nothing collected.").foregroundStyle(.secondary) }
                        ForEach(evidence) { e in
                            DisclosureGroup(LocalizedStringKey(e.title)) {
                                Text(e.text).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    } else {
                        HStack(spacing: 10) { ProgressView(); Text("Collecting logs, services and recent changes …").foregroundStyle(.secondary) }
                    }
                } header: {
                    Text("On the server right now")
                }
                Section {
                    ForEach([Engine.claudeCode, .codex, .ownKey]) { engine in
                        Button { start(engine) } label: { EngineRow(engine: engine, ready: isReady(engine)) }
                            .buttonStyle(.plain)
                            .disabled(evidence == nil)
                            .accessibilityIdentifier("incident.\(engine.rawValue)")
                    }
                } header: {
                    Text("Investigate with")
                } footer: {
                    Text("The agent gets these facts, looks further and suggests a fix without changing anything. You apply the fix with one tap.")
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Incident")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $thread) { AgentChatView(thread: $0, server: server) }
        .sheet(item: $signingIn) { cli in CLILoginView(server: server, cli: cli) }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .task { await load() }
        .task { await AgentStatus.shared.refresh(server) }
    }

    private func isReady(_ engine: Engine) -> Bool {
        if let cli = engine.serverCLI { return AgentStatus.shared.isSignedIn(cli, on: server) != false }
        return AppSettings.shared.isConfigured
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            let status = Uptime.parse(try await conn.run(Uptime.statusCommand, timeout: .seconds(30)).stdout)
            guard let found = status.checks.first(where: { $0.id == checkID }) else {
                error = String(localized: "This check isn't on the server anymore.")
                return
            }
            check = found
            evidence = Incident.parse(try await conn.run(Incident.evidenceCommand(url: found.url, lastHealthy: found.lastHealthy), timeout: .seconds(90)).stdout)
        } catch {
            self.error = error.localizedDescription
            if check != nil && evidence == nil { evidence = [] }
        }
    }

    private func start(_ engine: Engine) {
        if let cli = engine.serverCLI, AgentStatus.shared.isSignedIn(cli, on: server) == false { signingIn = cli; return }
        if engine == .ownKey && !AppSettings.shared.isConfigured { showingSettings = true; return }
        guard let check else { return }
        let t = ChatThread(server: server, workingDirectory: server.recentDirectories.first ?? server.workingDirectory, engine: engine)
        t.title = String(localized: "Why is \(check.name) down?")
        context.insert(t)
        IncidentLinks.set(check.id, for: t.id)
        // Diagnosis only: the CLIs can't change anything in this turn; the fix comes after the user's tap.
        PendingPrompt.set(Incident.prompt(check: check, evidence: evidence ?? []), for: t.id, access: .readOnly)
        thread = t
    }
}

/// An agent's "Suggested fix", ready to apply: the commands, and one tap that lets the agent run them.
struct SuggestedFixBar: View {
    let commands: String
    let apply: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Suggested fix", systemImage: "wrench.adjustable").font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Not now")
            }
            ScrollView {
                Text(commands).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(maxHeight: 72)
            .padding(8)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Button(action: apply) { Text("Apply fix").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .accessibilityIdentifier("fix.apply")
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }
}
