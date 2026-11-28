import DeckhandCore
import DeckhandSSH
import SwiftUI
import UniformTypeIdentifiers

/// Agent skills on a server: write one, or import it from a git repository, a URL or a file, then hand it to Claude
/// Code and Codex. The own-key agent sees them too and reads one when a task matches.
struct SkillsView: View {
    let server: Server
    private var connections: Connections { .shared }
    @State private var skills: [Skills.Skill]?
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var editing: SkillDraft?
    @State private var importingRepo = false
    @State private var importingURL = false
    @State private var importingFile = false
    @State private var source = ""
    @State private var removing: Skills.Skill?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let notice { Label(notice, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary) }
            if let skills {
                if skills.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No skills yet").font(.headline)
                            Text("A skill is a folder with a SKILL.md: when to use it, then step-by-step instructions. Write one here, or import skills from a git repository such as github.com/anthropics/skills.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                ForEach(skills) { s in
                    NavigationLink { SkillDetailView(server: server, skill: s) { Task { await load() } } } label: { row(s) }
                        .accessibilityIdentifier("skill.\(s.name)")
                        .swipeActions { Button("Remove", role: .destructive) { removing = s } }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
            Section {
                EmptyView()
            } footer: {
                Text("Claude Code reads ~/.claude/skills, Codex ~/.codex/skills. Tasks with your own key see every skill's name and description and open the one that fits.")
            }
        }
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { editing = SkillDraft() } label: { Label("Write a skill", systemImage: "square.and.pencil") }
                    Button { source = "https://github.com/"; importingRepo = true } label: { Label("Import from a git repository", systemImage: "arrow.down.doc") }
                    Button { source = "https://"; importingURL = true } label: { Label("Import a SKILL.md from a URL", systemImage: "link") }
                    Button { importingFile = true } label: { Label("Import a SKILL.md file", systemImage: "doc") }
                } label: {
                    if busy { ProgressView() } else { Image(systemName: "plus") }
                }
                .disabled(busy)
                .accessibilityLabel("Add a skill")
                .accessibilityIdentifier("skills.add")
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .appSheet(item: $editing) { d in SkillEditor(draft: d) { name, md, targets in Task { await write(name: name, md: md, targets: targets) } } }
        .alert("Import from a git repository", isPresented: $importingRepo) {
            TextField("https://github.com/…", text: $source).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("skills.repoURL")
            Button("Import") { Task { await importRepo(source) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every folder with a SKILL.md in it is imported for Claude Code and Codex. Nothing from the repository runs.")
        }
        .alert("Import a SKILL.md from a URL", isPresented: $importingURL) {
            TextField("https://…/SKILL.md", text: $source).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Import") { Task { await importURL(source) } }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.plainText, .text, .data]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) { editing = SkillDraft(fromSkillMD: text, fallbackName: url.deletingLastPathComponent().lastPathComponent) }
        }
        .confirmationDialog(removing.map { String(localized: "Remove “\($0.name)”?") } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove from Claude Code and Codex", role: .destructive) { if let s = removing { Task { await remove(s) } } }
        }
    }

    private func row(_ s: Skills.Skill) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(s.name).font(Theme.mono)
            if !s.description.isEmpty { Text(s.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            HStack(spacing: 6) {
                ForEach(Skills.Target.allCases, id: \.self) { t in
                    Text(t.displayName).font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((s.targets.contains(t) ? Theme.accent.opacity(0.14) : Color.secondary.opacity(0.08)), in: Capsule())
                        .foregroundStyle(s.targets.contains(t) ? Theme.accent : .secondary)
                        .strikethrough(!s.targets.contains(t))
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func shell(_ command: String, timeout: Int = 30) async throws -> String {
        try await connections.connection(for: server).run(command, timeout: .seconds(timeout)).stdout
    }

    private func load() async {
        #if DEBUG
        // DECKHAND_SEED_SKILLS="claude,name,description|codex,name,description": a list without a server.
        if let seed = ProcessInfo.processInfo.environment["DECKHAND_SEED_SKILLS"] {
            skills = Skills.parseList(seed.replacingOccurrences(of: "|", with: "\n").replacingOccurrences(of: ",", with: "\t"))
            return
        }
        #endif
        do { skills = Skills.parseList(try await shell(Skills.listCommand)); error = nil } catch { self.error = error.localizedDescription }
    }

    private func write(name: String, md: String, targets: Set<Skills.Target>) async {
        guard let cmd = Skills.writeCommand(name: name, skillMD: md, targets: targets) else { return }
        await perform(cmd, done: String(localized: "Saved “\(name)”."))
    }

    private func importRepo(_ url: String) async {
        guard let cmd = Skills.importGitCommand(url: url.trimmingCharacters(in: .whitespaces), targets: Set(Skills.Target.allCases)) else {
            error = String(localized: "Use an https:// address of a git repository."); return
        }
        busy = true; defer { busy = false }
        do {
            let out = try await shell(cmd + " 2>&1", timeout: 180)
            let names = out.split(separator: "\n").filter { $0.hasPrefix("@@skill ") }.map { String($0.dropFirst(8)) }
            if out.contains("@@none") { error = String(localized: "That repository has no SKILL.md.") }
            else if !out.contains("@@ok") { error = out.split(separator: "\n").last.map(String.init) ?? String(localized: "The import didn't work.") }
            else { error = nil; notice = String(localized: "Imported \(names.count) skills: \(names.joined(separator: ", "))") }
        } catch { self.error = error.localizedDescription }
        await load()
    }

    private func importURL(_ raw: String) async {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), url.scheme == "https" else {
            error = String(localized: "Use an https:// address."); return
        }
        busy = true; defer { busy = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400, let text = String(data: data, encoding: .utf8), data.count < 512_000 else {
                error = String(localized: "That address didn't give a SKILL.md."); return
            }
            editing = SkillDraft(fromSkillMD: text, fallbackName: url.deletingLastPathComponent().lastPathComponent)
        } catch { self.error = error.localizedDescription }
    }

    private func remove(_ s: Skills.Skill) async {
        removing = nil
        let cmd = s.targets.compactMap { Skills.removeCommand(name: s.name, from: $0) }.joined(separator: " && ")
        await perform(cmd, done: String(localized: "Removed “\(s.name)”."))
    }

    private func perform(_ cmd: String, done: String) async {
        busy = true; defer { busy = false }
        do {
            let out = try await shell(cmd + " 2>&1")
            if out.contains("@@ok") { error = nil; notice = done } else { error = out.trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch { self.error = error.localizedDescription }
        await load()
    }
}

/// A skill being written or reviewed before it is saved.
struct SkillDraft: Identifiable {
    let id = UUID()
    var name = ""
    var description = ""
    var body = ""

    init() {}

    init(fromSkillMD text: String, fallbackName: String) {
        let fm = Skills.frontMatter(text)
        name = Skills.slug(fm?.name ?? fallbackName)
        description = fm?.description ?? ""
        if fm != nil, let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            body = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            body = text
        }
    }
}

private struct SkillEditor: View {
    @State var draft: SkillDraft
    let save: (_ name: String, _ skillMD: String, _ targets: Set<Skills.Target>) -> Void
    @State private var targets = Set(Skills.Target.allCases)
    @Environment(\.dismiss) private var dismiss

    private var name: String { Skills.slug(draft.name) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name).font(Theme.mono)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("skill.name")
                    TextField("When to use it", text: $draft.description, axis: .vertical).lineLimit(2...4)
                        .accessibilityIdentifier("skill.description")
                } footer: {
                    Text(name.isEmpty ? "A short name, e.g. deploy-web." : "Saved as \(name). The description tells the agent when this skill fits.")
                }
                Section("Instructions") {
                    TextField("Steps, commands, what to check …", text: $draft.body, axis: .vertical)
                        .lineLimit(8...30)
                        .accessibilityIdentifier("skill.body")
                }
                Section("Use in") {
                    ForEach(Skills.Target.allCases, id: \.self) { t in
                        Toggle(t.displayName, isOn: Binding(get: { targets.contains(t) }, set: { if $0 { targets.insert(t) } else { targets.remove(t) } }))
                    }
                }
            }
            .navigationTitle("Skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(name, Skills.template(name: name, description: draft.description, body: draft.body), targets)
                        dismiss()
                    }
                    .disabled(!Skills.isValidName(name) || draft.description.trimmingCharacters(in: .whitespaces).isEmpty
                              || draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || targets.isEmpty)
                    .accessibilityIdentifier("skill.save")
                }
            }
        }
    }
}

/// One skill: its SKILL.md, and which CLIs have it.
private struct SkillDetailView: View {
    let server: Server
    let skill: Skills.Skill
    let changed: () -> Void
    @State private var text: String?
    @State private var targets: Set<Skills.Target> = []
    @State private var error: String?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            Section("Use in") {
                ForEach(Skills.Target.allCases, id: \.self) { t in
                    Toggle(t.displayName, isOn: Binding(get: { targets.contains(t) }, set: { on in Task { await set(t, on) } }))
                        .disabled(targets == [t])   // the last copy is removed from the list instead
                }
            }
            Section("SKILL.md") {
                if let text { Text(text).font(Theme.monoSmall).textSelection(.enabled) } else { ProgressView() }
            }
        }
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            targets = skill.targets
            text = try? await Connections.shared.connection(for: server)
                .run("cat \(skill.path.replacingOccurrences(of: "~", with: "\"$HOME\""))/SKILL.md", timeout: .seconds(20)).stdout
        }
    }

    private func set(_ t: Skills.Target, _ on: Bool) async {
        let from = targets.first { $0 != t } ?? t
        let cmd = on ? Skills.copyCommand(name: skill.name, from: from, to: t) : Skills.removeCommand(name: skill.name, from: t)
        guard let cmd else { return }
        do {
            let out = try await Connections.shared.connection(for: server).run(cmd + " 2>&1", timeout: .seconds(30)).stdout
            if out.contains("@@ok") { if on { targets.insert(t) } else { targets.remove(t) }; error = nil; changed() } else { error = out }
        } catch { self.error = error.localizedDescription }
    }
}
