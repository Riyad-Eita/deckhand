import DeckhandCore
import DeckhandSSH
import SwiftUI

/// GitHub pull requests through the server's `gh`: the ones waiting for your review, and yours.
struct PullRequestsView: View {
    let server: Server
    @State private var listing: PullRequests.Listing?
    @State private var error: String?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let l = listing {
                if l.noGH || l.error != nil {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Connect GitHub first").font(.headline)
                            Text("Pull requests come from the GitHub CLI on this server. Sign in under Tools → Connect GitHub.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if let e = l.error { Text(e).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(3) }
                        }
                    }
                } else {
                    let review = l.items.filter(\.reviewRequested), mine = l.items.filter { !$0.reviewRequested }
                    Section("Waiting for your review") {
                        if review.isEmpty { Text("Nothing waits for you.").foregroundStyle(.secondary) }
                        ForEach(review) { row($0) }
                    }
                    if !mine.isEmpty {
                        Section("Yours") { ForEach(mine) { row($0) } }
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Pull requests")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ p: PullRequests.Item) -> some View {
        NavigationLink { PullRequestDetailView(server: server, item: p) { Task { await load() } } } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text("\(p.repo) #\(p.number)").font(Theme.monoSmall)
                    Text("· \(p.author)")
                    if let u = p.updated { Text("· \(u, format: .relative(presentation: .named))") }
                    if p.isDraft { Text("· Draft") }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityIdentifier("pr.\(p.repo)#\(p.number)")
    }

    private func load() async {
        #if DEBUG
        if let seed = ProcessInfo.processInfo.environment["DECKHAND_SEED_PRS"] { listing = PullRequests.parseList(seed); return }
        #endif
        do {
            let conn = try await Connections.shared.connection(for: server)
            listing = PullRequests.parseList(try await conn.run(PullRequests.listCommand, timeout: .seconds(60)).stdout)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

/// One pull request: facts and checks, an AI summary with risk notes, the files and diff, then review or merge.
struct PullRequestDetailView: View {
    let server: Server
    let item: PullRequests.Item
    let changed: () -> Void
    @State private var detail: PullRequests.Detail?
    @State private var error: String?
    @State private var notice: String?
    @State private var review: PullRequests.Review?
    @State private var reviewSource: String?
    @State private var reviewing = false
    @State private var writing: PullRequests.Verdict?
    @State private var merging = false
    @State private var method: PullRequests.MergeMethod = .squash
    @State private var deleteBranch = true
    @State private var busy = false
    @State private var showAllDiff = false

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let notice { Label(notice, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary) }
            if let d = detail {
                Section {
                    Text(d.title).font(.headline)
                    LabeledContent("Branch") { Text("\(d.head) → \(d.base)").font(Theme.monoSmall) }
                    LabeledContent("Changes") { Text("+\(d.additions) −\(d.deletions) in \(d.files.count) files").monospacedDigit() }
                    if d.checks.passed + d.checks.failed + d.checks.pending > 0 {
                        LabeledContent("Checks") {
                            HStack(spacing: 8) {
                                if d.checks.failed > 0 { Label("\(d.checks.failed)", systemImage: "xmark.circle.fill").foregroundStyle(.red) }
                                if d.checks.pending > 0 { Label("\(d.checks.pending)", systemImage: "clock").foregroundStyle(.orange) }
                                Label("\(d.checks.passed)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                            .labelStyle(.titleAndIcon).font(.subheadline.monospacedDigit())
                        }
                    }
                    if !d.body.isEmpty { MarkdownView(String(d.body.prefix(3000))).font(.subheadline) }
                } header: {
                    Text("\(item.repo) #\(item.number) · \(d.author)")
                }
                reviewSection(d)
                Section("Files") {
                    ForEach(Array(d.files.prefix(80).enumerated()), id: \.offset) { _, f in
                        HStack {
                            Text(f.path).font(Theme.monoSmall).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text("+\(f.additions)").foregroundStyle(.green)
                            Text("−\(f.deletions)").foregroundStyle(.red)
                        }
                        .font(.caption.monospacedDigit())
                    }
                }
                Section {
                    PRDiffText(diff: d.diff, limit: showAllDiff ? nil : 400)
                    if !showAllDiff && d.diff.split(separator: "\n", omittingEmptySubsequences: false).count > 400 {
                        Button("Show the whole diff") { showAllDiff = true }
                    }
                    if d.diffTruncated { Text("The diff is cut at 300 kB.").font(.caption).foregroundStyle(.secondary) }
                } header: {
                    Text("Diff")
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("#\(item.number)")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { if detail != nil { actionBar } }
        .task { await load() }
        .appSheet(item: $writing) { v in
            ReviewComposer(verdict: v) { text in Task { await submit(v, text) } }
        }
        .confirmationDialog("Merge #\(item.number)?", isPresented: $merging, titleVisibility: .visible) {
            ForEach(PullRequests.MergeMethod.allCases, id: \.self) { m in
                Button(mergeLabel(m)) { method = m; Task { await merge() } }
            }
        } message: {
            Text(detail?.mergeable == "CONFLICTING" ? "GitHub reports conflicts; the merge will likely fail." : "The branch is deleted after the merge.")
        }
    }

    @ViewBuilder private func reviewSection(_ d: PullRequests.Detail) -> some View {
        Section {
            if let review {
                Text(review.summary).font(.subheadline)
                if review.risks.isEmpty {
                    Label("No risks found", systemImage: "checkmark.shield").font(.subheadline).foregroundStyle(.green)
                } else {
                    ForEach(review.risks, id: \.self) { r in
                        Label(r, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                    }
                }
                if let reviewSource { Text(reviewSource).font(.caption2).foregroundStyle(.tertiary) }
            } else {
                Button { Task { await summarize(d) } } label: {
                    HStack { Label("Summarize and check for risks", systemImage: "sparkles"); Spacer(); if reviewing { ProgressView() } }
                }
                .disabled(reviewing || !QuickAI.isAvailable)
                .accessibilityIdentifier("pr.summarize")
                if !QuickAI.isAvailable { Text("Needs Apple Intelligence on this device or a model key in Settings.").font(.caption).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Review")
        } footer: {
            Text("A first read, not a verdict: check the diff before you approve.")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button { writing = .comment } label: { Label("Comment", systemImage: "text.bubble") }
                Button { writing = .requestChanges } label: { Label("Request changes", systemImage: "exclamationmark.bubble") }
                Button { writing = .approve } label: { Label("Approve with a comment", systemImage: "checkmark.bubble") }
            } label: {
                Text("Review").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("pr.reviewMenu")
            Button { Task { await submit(.approve, "") } } label: { Text("Approve").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).tint(.green)
                .accessibilityIdentifier("pr.approve")
            Button { merging = true } label: { Label("Merge", systemImage: "arrow.triangle.merge").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("pr.merge")
        }
        .disabled(busy)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .controlSize(.large)
        .padding(.horizontal).padding(.vertical, 10)
        .background(.bar)
    }

    private func mergeLabel(_ m: PullRequests.MergeMethod) -> String {
        switch m {
        case .squash: String(localized: "Squash and merge")
        case .merge: String(localized: "Create a merge commit")
        case .rebase: String(localized: "Rebase and merge")
        }
    }

    // MARK: - Actions

    private func run(_ command: String, timeout: Int = 60) async throws -> String {
        try await Connections.shared.connection(for: server).run(command, timeout: .seconds(timeout)).stdout
    }

    private func load() async {
        #if DEBUG
        if let seed = ProcessInfo.processInfo.environment["DECKHAND_SEED_PR_DETAIL"] {
            detail = PullRequests.parseDetail(seed.replacingOccurrences(of: "|", with: "\n")); return
        }
        #endif
        guard let cmd = PullRequests.detailCommand(repo: item.repo, number: item.number) else { return }
        do {
            let out = try await run(cmd, timeout: 90)
            if let d = PullRequests.parseDetail(out) { detail = d; error = nil } else { error = out.split(separator: "\n").first.map(String.init) ?? String(localized: "The pull request couldn't be loaded.") }
        } catch { self.error = error.localizedDescription }
    }

    private func summarize(_ d: PullRequests.Detail) async {
        reviewing = true; defer { reviewing = false }
        do {
            guard let r = try await QuickAI.run(PullRequests.reviewInstructions, PullRequests.reviewPrompt(d)) else { return }
            review = PullRequests.parseReview(r.text)
            reviewSource = switch r.source {
            case .onDevice: String(localized: "On-device model")
            case .key(let model): model
            }
        } catch { self.error = error.localizedDescription }
    }

    private func submit(_ verdict: PullRequests.Verdict, _ text: String) async {
        guard let cmd = PullRequests.reviewCommand(repo: item.repo, number: item.number, verdict: verdict, body: text) else { return }
        await perform(cmd, done: verdict == .approve ? String(localized: "Approved.") : verdict == .comment ? String(localized: "Comment posted.") : String(localized: "Changes requested."))
    }

    private func merge() async {
        guard let cmd = PullRequests.mergeCommand(repo: item.repo, number: item.number, method: method, deleteBranch: deleteBranch) else { return }
        await perform(cmd, done: String(localized: "Merged."))
    }

    private func perform(_ cmd: String, done: String) async {
        busy = true; defer { busy = false }
        do {
            let out = try await run(cmd)
            if out.contains("@@ok") { notice = done; error = nil; changed() } else { error = out.trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch { self.error = error.localizedDescription }
    }
}

/// A unified diff, colored per line.
private struct PRDiffText: View {
    let diff: String
    let limit: Int?

    var body: some View {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = limit.map { Array(lines.prefix($0)) } ?? lines
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                    Text(String(line).isEmpty ? " " : String(line))
                        .font(Theme.monoSmall)
                        .foregroundStyle(color(line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line))
                }
            }
        }
        .textSelection(.enabled)
    }

    private func color(_ l: Substring) -> Color {
        if l.hasPrefix("+++") || l.hasPrefix("---") || l.hasPrefix("diff ") || l.hasPrefix("index ") { return .secondary }
        if l.hasPrefix("@@") { return Theme.accent }
        return .primary
    }

    private func background(_ l: Substring) -> Color {
        if l.hasPrefix("+") && !l.hasPrefix("+++") { return Color.green.opacity(0.13) }
        if l.hasPrefix("-") && !l.hasPrefix("---") { return Color.red.opacity(0.13) }
        return .clear
    }
}

private struct ReviewComposer: View {
    let verdict: PullRequests.Verdict
    let send: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField(verdict == .approve ? "Optional comment" : "What should change, or what you noticed", text: $text, axis: .vertical)
                    .lineLimit(5...14)
                    .accessibilityIdentifier("pr.reviewText")
            }
            .navigationTitle(verdict == .approve ? "Approve" : verdict == .comment ? "Comment" : "Request changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send(text); dismiss() }
                        .disabled(verdict != .approve && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

extension PullRequests.Verdict: Identifiable { public var id: String { rawValue } }
