import DeckhandCore
import SwiftUI

/// Claude Code and Codex sessions already on the server — e.g. started on the laptop — by folder. Open one to read it
/// and continue it here; the next message resumes the same session on the server.
struct CLISessionsView: View {
    let server: Server
    /// Opens the task that continues the session.
    let open: (ChatThread) -> Void
    @Environment(Connections.self) private var connections
    @State private var sessions: [CLISessions.Session]?
    @State private var error: String?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let sessions {
                if sessions.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No sessions on this server yet").font(.headline)
                            Text("Sessions you start with claude or codex on this server — on your laptop over SSH, say — show up here, and you can carry on with them from your iPhone.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                ForEach(CLISessions.byFolder(sessions), id: \.folder) { group in
                    Section(group.folder) {
                        ForEach(group.sessions) { s in
                            NavigationLink { CLISessionDetail(server: server, session: s, open: open) } label: { row(s) }
                                .accessibilityIdentifier("session.\(s.title)")
                        }
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Sessions on the server")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if sessions == nil { await load() } }
    }

    private func row(_ s: CLISessions.Session) -> some View {
        HStack(spacing: 12) {
            BrandIcon(brand: s.cli == .claudeCode ? .claude : .codex, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).lineLimit(2)
                Text(s.modified, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            sessions = CLISessions.parseList(try await conn.run(CLISessions.listCommand(), timeout: .seconds(45)).stdout)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct CLISessionDetail: View {
    let server: Server
    let session: CLISessions.Session
    let open: (ChatThread) -> Void
    @Environment(Connections.self) private var connections
    @Environment(\.modelContext) private var context
    @State private var messages: [Message]?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error { ProblemView(message: error, compact: true) }
                if let messages {
                    if messages.isEmpty { Text("This session has no messages yet.").foregroundStyle(.secondary) }
                    ForEach(messages.suffix(40)) { m in
                        ForEach(Array(m.blocks.enumerated()), id: \.offset) { _, b in block(b, role: m.role) }
                    }
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            Button { continueHere() } label: {
                Label("Continue here", systemImage: "arrow.right.circle.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 16).padding(.bottom, 8)
            .disabled(messages == nil)
            .accessibilityIdentifier("session.continue")
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder private func block(_ b: ContentBlock, role: Role) -> some View {
        switch b {
        case .text(let t):
            if role == .user {
                Text(t).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.userBubble.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ReplyText(text: t)
            }
        case .toolUse(let c):
            Label(c.input["command"]?.stringValue.map { "$ \($0)" } ?? c.name, systemImage: "terminal")
                .font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(3)
        default: EmptyView()
        }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            let r = try await conn.run(CLISessions.transcriptCommand(cli: session.cli, id: session.id), timeout: .seconds(45))
            guard r.exitCode == 0 else { throw ToolError.failed(r.stderr.isEmpty ? String(localized: "Couldn't read the session.") : r.stderr) }
            messages = CLISessions.parseTranscript(cli: session.cli, r.stdout)
        } catch { self.error = error.localizedDescription }
    }

    /// A task bound to the session: the transcript as history, the next message resumes it on the server.
    private func continueHere() {
        let thread = ChatThread(server: server, workingDirectory: session.folder, engine: session.cli == .claudeCode ? .claudeCode : .codex)
        thread.title = session.title
        thread.cliSessionID = session.id
        thread.messages = messages ?? []
        context.insert(thread)
        try? context.save()
        open(thread)
    }
}
