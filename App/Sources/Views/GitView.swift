import DeckhandCore
import SwiftUI

/// Git repositories on a server.
struct GitReposView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var repos: [String]?
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            if let repos {
                if repos.isEmpty {
                    ContentUnavailableView("No repositories found", systemImage: "arrow.triangle.branch",
                                           description: Text("Deckhand looks for Git repositories up to four folders below your home folder."))
                } else {
                    Section {
                        ForEach(repos, id: \.self) { path in
                            NavigationLink { GitRepoView(server: server, repo: path) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((path as NSString).lastPathComponent).font(.body.weight(.medium))
                                    Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                }
                            }
                        }
                    }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Git")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            let extra = ([server.workingDirectory] + server.recentDirectories).filter { $0 != "~" && !$0.isEmpty }
            let out = try await conn.run(Git.findCommand(extra: extra), timeout: .seconds(40)).stdout
            let home = try await conn.run("printf %s \"$HOME\"", timeout: .seconds(10)).stdout
            repos = out.split(separator: "\n").map { line in
                let p = String(line)
                return !home.isEmpty && p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
            }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Status, diffs, staging, commit, branches, pull and push for one repository.
struct GitRepoView: View {
    let server: Server
    let repo: String
    @Environment(Connections.self) private var connections
    @State private var status: Git.Status?
    @State private var message = ""
    @State private var busy: String?
    @State private var result: String?
    @State private var hint: String?
    @State private var showBranches = false
    @State private var showIdentity = false
    @State private var confirmDiscard: Git.FileChange?
    @State private var suggesting = false
    @FocusState private var messageFocused: Bool

    var body: some View {
        List {
            if let status {
                Section {
                    HStack {
                        Label(status.branch ?? String(localized: "Detached HEAD"), systemImage: "arrow.triangle.branch").font(.body.weight(.medium))
                        Spacer()
                        if status.ahead > 0 { Text("↑\(status.ahead)").monospacedDigit() }
                        if status.behind > 0 { Text("↓\(status.behind)").monospacedDigit() }
                    }
                    .font(.subheadline)
                    HStack(spacing: 8) {
                        action("Pull", "arrow.down", Git.pullCommand(repo))
                        action("Push", "arrow.up", Git.pushCommand(repo))
                        Button { showBranches = true } label: { Label("Branches", systemImage: "list.bullet") }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    if let result {
                        Text(result).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(6)
                    }
                    if let hint {
                        Label(LocalizedStringKey(hint), systemImage: "lightbulb").font(.footnote).foregroundStyle(.orange)
                        if hint.contains("who you are") { Button("Set name and email") { showIdentity = true }.font(.footnote) }
                    }
                }
                if status.isClean {
                    Section { Label("Nothing to commit — the working tree is clean.", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                }
                if !status.staged.isEmpty {
                    Section {
                        ForEach(status.staged) { f in fileRow(f, staged: true) }
                    } header: {
                        HStack { Text("Staged"); Spacer(); Button("Unstage all") { run(Git.unstageCommand(repo, paths: status.staged.map(\.path))) }.font(.caption.weight(.semibold)) }
                    }
                    Section {
                        TextField("Commit message", text: $message, axis: .vertical).lineLimit(2...8).focused($messageFocused)
                            .accessibilityIdentifier("git.message")
                        HStack {
                            Button { Task { await suggest() } } label: {
                                if suggesting { ProgressView().controlSize(.small) } else { Label("Suggest", systemImage: "sparkles") }
                            }
                            .disabled(suggesting)
                            Spacer()
                            Button("Commit") {
                                messageFocused = false
                                run(Git.commitCommand(repo, message: message.trimmingCharacters(in: .whitespacesAndNewlines))) { ok in if ok { message = "" } }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy != nil)
                            .accessibilityIdentifier("git.commit")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                if !status.unstaged.isEmpty {
                    Section {
                        ForEach(status.unstaged) { f in fileRow(f, staged: false) }
                    } header: {
                        HStack { Text("Changes"); Spacer(); Button("Stage all") { run(Git.stageCommand(repo, paths: status.unstaged.map(\.path))) }.font(.caption.weight(.semibold)) }
                    }
                }
                Section {
                    NavigationLink("History") { GitLogView(server: server, repo: repo) }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle((repo as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { if busy != nil { ProgressView() } } }
        .task { await refresh(fetch: true) }
        .refreshable { await refresh(fetch: true) }
        .sheet(isPresented: $showBranches, onDismiss: { Task { await refresh() } }) { GitBranchesView(server: server, repo: repo) }
        .sheet(isPresented: $showIdentity, onDismiss: { Task { await refresh() } }) { GitIdentityView(server: server, repo: repo) }
        .confirmationDialog("Throw away the changes to \(confirmDiscard?.path ?? "")?", isPresented: Binding(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } }), titleVisibility: .visible) {
            Button("Throw away", role: .destructive) { if let f = confirmDiscard { run(Git.discardCommand(repo, file: f)) } }
        } message: {
            Text("This can't be undone.")
        }
    }

    @ViewBuilder private func fileRow(_ f: Git.FileChange, staged: Bool) -> some View {
        NavigationLink {
            GitDiffView(server: server, repo: repo, file: f, staged: staged)
        } label: {
            HStack(spacing: 10) {
                KindBadge(kind: staged ? f.staged : f.unstaged)
                VStack(alignment: .leading, spacing: 1) {
                    Text((f.path as NSString).lastPathComponent).lineLimit(1)
                    let dir = (f.path as NSString).deletingLastPathComponent
                    if !dir.isEmpty { Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if staged {
                Button("Unstage") { run(Git.unstageCommand(repo, paths: [f.path])) }.tint(.orange)
            } else {
                Button("Stage") { run(Git.stageCommand(repo, paths: [f.path])) }.tint(.green)
                Button("Discard", role: .destructive) { confirmDiscard = f }
            }
        }
    }

    private func action(_ title: LocalizedStringKey, _ symbol: String, _ command: String) -> some View {
        Button { run(command) } label: { Label(title, systemImage: symbol) }.disabled(busy != nil)
    }

    private func run(_ command: String, then: @escaping (Bool) -> Void = { _ in }) {
        Task {
            busy = command
            defer { busy = nil }
            do {
                let conn = try await connections.connection(for: server)
                let r = try await conn.run(command, timeout: .seconds(120))
                let out = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                result = out.isEmpty ? nil : out
                hint = r.exitCode == 0 ? nil : (Git.hint(for: out) ?? String(localized: "Git reported an error."))
                then(r.exitCode == 0)
            } catch {
                result = error.localizedDescription
            }
            await refresh()
        }
    }

    private func refresh(fetch: Bool = false) async {
        guard let conn = try? await connections.connection(for: server) else { return }
        if fetch { _ = try? await conn.run(Git.fetchCommand(repo), timeout: .seconds(30)) }
        if let r = try? await conn.run(Git.statusCommand(repo), timeout: .seconds(30)) { status = Git.parseStatus(r.stdout) }
    }

    /// A commit message from your own model key, or from Claude Code / Codex on the server.
    private func suggest() async {
        suggesting = true
        defer { suggesting = false }
        guard let conn = try? await connections.connection(for: server) else { return }
        let settings = AppSettings.shared
        if settings.isConfigured {
            guard let diff = try? await conn.run(Git.stagedDiffForMessage(repo), timeout: .seconds(30)).stdout else { return }
            let provider = Providers.make(settings.providerConfig)
            var text = ""
            do {
                for try await e in provider.stream(ChatRequest(system: "", messages: [.user(Git.commitMessagePrompt(diff: diff))], tools: [], maxTokens: 600)) {
                    if case .textDelta(let t) = e { text += t; message = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            } catch { hint = error.localizedDescription }
            return
        }
        let ask = "Write a git commit message for the staged diff on stdin. Imperative mood, subject under 72 characters, optional short body. Reply with the message only."
        let cmd = """
        cd \(ServerTools.shellPath(repo)) && D=$(git diff --cached --no-color | head -c 24000); M=
        # Claude Code first, then Codex — whichever is installed and signed in.
        command -v claude >/dev/null 2>&1 && M=$(printf '%s' "$D" | timeout 120 claude -p \(ShellQuote.quote(ask)) 2>/dev/null)
        [ -z "$M" ] && command -v codex >/dev/null 2>&1 && M=$(timeout 150 codex exec --skip-git-repo-check -s read-only \(ShellQuote.quote("Run `git diff --cached` in this folder and write a git commit message for it. Imperative mood, subject under 72 characters, optional short body. Reply with the message only.")) 2>/dev/null | tail -n 20)
        if [ -n "$M" ]; then printf '%s\\n' "$M"; else echo '@@none'; fi
        """
        guard let r = try? await conn.run(cmd, timeout: .seconds(180)) else { return }
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if out == "@@none" || out.isEmpty {
            hint = String(localized: "Add a model key in Settings, or sign in to Claude Code or Codex on this server, to get suggestions.")
        } else {
            message = out
        }
    }
}

private struct KindBadge: View {
    let kind: Git.FileChange.Kind?
    var body: some View {
        let (letter, color): (String, Color) = switch kind {
        case .added?: ("A", .green)
        case .deleted?: ("D", .red)
        case .renamed?: ("R", .blue)
        case .untracked?: ("U", .green)
        case .conflicted?: ("!", .red)
        case .typeChanged?: ("T", .orange)
        default: ("M", .orange)
        }
        Text(letter).font(.caption.weight(.bold).monospaced()).foregroundStyle(color)
            .frame(width: 22, height: 22).background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct GitDiffView: View {
    let server: Server
    let repo: String
    let file: Git.FileChange
    let staged: Bool
    @Environment(Connections.self) private var connections
    @State private var lines: [String]?

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            if let lines {
                if lines.isEmpty { Text("No text changes (binary file or only file mode).").foregroundStyle(.secondary).padding() }
                else { DiffText(lines: lines).padding() }
            } else {
                ProgressView().padding(40)
            }
        }
        .navigationTitle((file.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let conn = try? await connections.connection(for: server),
                  let r = try? await conn.run(Git.diffCommand(repo, file: file, staged: staged), timeout: .seconds(30)) else { lines = []; return }
            lines = r.stdout.split(separator: "\n", omittingEmptySubsequences: false).prefix(4000).map(String.init)
                .filter { !$0.hasPrefix("diff --git") && !$0.hasPrefix("index ") }
        }
    }
}

struct GitLogView: View {
    let server: Server
    let repo: String
    @Environment(Connections.self) private var connections
    @State private var commits: [Git.Commit]?

    var body: some View {
        List {
            ForEach(commits ?? []) { c in
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.subject).lineLimit(2)
                    HStack(spacing: 4) {
                        Text(c.hash).font(Theme.monoSmall)
                        Text("·"); Text(c.author); Text("·")
                        Text(c.date, format: .relative(presentation: .named))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay { if commits == nil { ProgressView() } }
        .navigationTitle("History")
        .task {
            guard let conn = try? await connections.connection(for: server),
                  let r = try? await conn.run(Git.logCommand(repo, count: 50), timeout: .seconds(30)) else { commits = []; return }
            commits = Git.parseLog(r.stdout)
        }
    }
}

struct GitBranchesView: View {
    let server: Server
    let repo: String
    @Environment(Connections.self) private var connections
    @Environment(\.dismiss) private var dismiss
    @State private var branches: [Git.Branch] = []
    @State private var newName = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Section {
                    HStack {
                        TextField("new-branch", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                        Button("Create") { Task { await switchTo(newName, create: true) } }.disabled(!Git.isValidBranchName(newName))
                    }
                } header: { Text("New branch from here") }
                Section("Branches") {
                    ForEach(branches) { b in
                        Button { Task { await switchTo(b.name, create: false) } } label: {
                            HStack {
                                Text(b.name).font(.body.monospaced()).foregroundStyle(.primary)
                                Spacer()
                                if b.isCurrent { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                        .disabled(b.isCurrent)
                    }
                }
            }
            .navigationTitle("Branches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                guard let conn = try? await connections.connection(for: server),
                      let r = try? await conn.run(Git.branchesCommand(repo), timeout: .seconds(20)) else { return }
                branches = Git.parseBranches(r.stdout)
            }
        }
    }

    private func switchTo(_ name: String, create: Bool) async {
        guard let conn = try? await connections.connection(for: server),
              let r = try? await conn.run(Git.switchCommand(repo, branch: name, create: create), timeout: .seconds(30)) else { return }
        if r.exitCode == 0 { dismiss() } else { error = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

struct GitIdentityView: View {
    let server: Server
    let repo: String
    @Environment(Connections.self) private var connections
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name).textContentType(.name)
                    TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                } footer: {
                    Text("Saved in this repository's Git settings on the server and shown on your commits.")
                }
            }
            .navigationTitle("Who's committing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if let conn = try? await connections.connection(for: server) {
                                _ = try? await conn.run(Git.setIdentityCommand(repo, name: name, email: email), timeout: .seconds(15))
                            }
                            dismiss()
                        }
                    }
                    .disabled(name.isEmpty || !email.contains("@"))
                }
            }
        }
    }
}
