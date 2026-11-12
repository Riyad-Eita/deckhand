import DeckhandCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import os

struct AgentChatView: View {
    @State private var model: ChatModel
    @State private var draft = ""
    /// The reply whose suggested fix the user waved away.
    @State private var dismissedFix: UUID?
    /// The fix the user applied in this chat; once it ran, offer to make it automatic.
    @State private var appliedFix: String?
    @State private var settingUpRemedy = false
    /// The proposed regression check was added or waved away.
    @State private var checkHandled: UUID?
    @State private var checkAdded = false
    /// A house-rule block the user waved away.
    @State private var dismissedBlock: String?
    @State private var voice = VoiceInput.shared
    @FocusState private var composerFocused: Bool
    @State private var browsing: BrowserTarget?
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var choosingFile = false
    @State private var upload: (name: String, progress: Double)?
    /// Own key: pictures that go with the next message (downscaled JPEG).
    @State private var images: [Data] = []
    @State private var uploadError: String?

    init(thread: ChatThread, server: Server) {
        _model = State(initialValue: ChatModel.model(for: thread, server: server))
    }

    private var headerSubtitle: String {
        let engine = model.thread.engine
        var parts = [engine.shortTitle]
        if let cli = engine.serverCLI, let chosen = CLIModelMenu.summary(cli: cli, thread: model.thread, settings: AppSettings.shared) {
            parts.append(chosen)
        }
        parts.append(model.thread.workingDirectory)
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.messages.isEmpty && !model.isRunning {
                        EmptyChatHint(server: model.server, workingDirectory: model.thread.workingDirectory, engine: model.thread.engine) { draft = $0; composerFocused = true }
                    }
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { i, message in
                        if i == model.thread.historyStart, i > 0, let summary = model.thread.historySummary {
                            SummaryDivider(summary: summary)
                        }
                        MessageView(message: message, model: model)
                    }
                    if model.isRunning { LiveTurnView(model: model) }
                    if let notice = model.notice {
                        Label(notice, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = model.error {
                        ProblemView(message: error, compact: true)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.messages.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.liveText) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let approval = model.pendingApproval {
                    ApprovalBar(approval: approval)
                } else if let plan = model.planOffer {
                    PlanBar(total: plan.steps.count, skipped: model.planSkipped.count) {
                        let kept = plan.steps.enumerated().filter { !model.planSkipped.contains($0.offset) }.map(\.element)
                        model.planHandled = plan.message
                        model.planSkipped = []
                        model.send(PlanMode.runPrompt(kept), plan: false)
                    } adjust: {
                        model.planHandled = plan.message
                        model.planSkipped = []
                        draft = String(localized: "Change the plan: ")
                        composerFocused = true
                    } cancel: {
                        model.planHandled = plan.message
                        model.planSkipped = []
                    }
                } else if let fix = suggestedFix {
                    SuggestedFixBar(commands: fix.commands) {
                        dismissedFix = fix.message
                        appliedFix = fix.commands
                        model.send(Incident.applyPrompt, access: .full)
                    } dismiss: {
                        dismissedFix = fix.message
                    }
                } else if let offer = checkOffer {
                    CheckOffer(check: offer.check, added: checkAdded) {
                        Task { await addCheck(offer.check, message: offer.message) }
                    } dismiss: {
                        checkHandled = offer.message
                    }
                } else if appliedFix != nil, !model.isRunning, model.error == nil, IncidentLinks.check(for: model.thread.id) != nil {
                    AutoFixOffer { settingUpRemedy = true } dismiss: { appliedFix = nil }
                } else if let block = ruleBlock {
                    RuleBlockedBar(title: HouseRulesStore.rules(for: model.server)?.title(for: block) ?? block.title) {
                        dismissedBlock = block.fingerprint
                        Task { await allowOnce(block) }
                    } dismiss: {
                        dismissedBlock = block.fingerprint
                    }
                }
                if let upload {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.doc").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Uploading \(upload.name)").font(.caption).lineLimit(1)
                            ProgressView(value: upload.progress)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 8)
                    .accessibilityIdentifier("upload.progress")
                }
                if let uploadError {
                    Text(uploadError).font(.caption).foregroundStyle(.red).padding(.horizontal, 16).padding(.top, 6)
                }
                composer
            }
            .background(.bar)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    BrandIcon(brand: model.thread.engine.brand, size: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.thread.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(headerSubtitle)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                .frame(maxWidth: 260)
            }
            if let cli = model.thread.engine.serverCLI {
                ToolbarItem(placement: .primaryAction) {
                    CLIModelMenu(thread: model.thread, server: model.server, cli: cli)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { FilesChangedView(server: model.server, thread: model.thread) } label: {
                    Image(systemName: "doc.badge.clock")
                }
                .accessibilityLabel("Changed files")
                .accessibilityIdentifier("chat.changes")
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { ActionLogView(thread: model.thread, server: model.server) } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .accessibilityLabel("Action log")
                .accessibilityIdentifier("chat.log")
            }
        }
        // Links to the server's localhost (http://localhost:3000) open through an SSH tunnel.
        .environment(\.explainFix, { model.send($0) })
        .environment(\.openURL, OpenURLAction { url in
            guard let port = ListeningPorts.localPort(in: url) else { return .systemAction }
            browsing = BrowserTarget(port: port, path: url.path.isEmpty ? "/" : url.path + (url.query.map { "?" + $0 } ?? ""))
            return .handled
        })
        .sheet(isPresented: $settingUpRemedy) {
            if let check = IncidentLinks.check(for: model.thread.id), let commands = appliedFix {
                RemedySheet(server: model.server, checkID: check, checkName: model.thread.title, initialCommands: commands) { appliedFix = nil }
            }
        }
        .sheet(item: $browsing) { BrowserSheet(server: model.server, port: $0.port, path: $0.path) }
        .onAppear { AppRouter.shared.visibleThread = model.thread.id }
        .onDisappear { if AppRouter.shared.visibleThread == model.thread.id { AppRouter.shared.visibleThread = nil } }
        .task {
            model.resumeIfNeeded()
            if let pending = PendingPrompt.take(for: model.thread.id), model.messages.isEmpty { model.send(pending.text, access: pending.access) }
            if let draft = PendingPrompt.takeDraft(for: model.thread.id) { self.draft = draft; composerFocused = true }
        }
        #if DEBUG
        .task {
            // DECKHAND_SEED_VOICE_FILE=<file in the app's tmp dir>: install Whisper if needed and dictate that file.
            if let name = ProcessInfo.processInfo.environment["DECKHAND_SEED_VOICE_FILE"] {
                if !voice.isInstalled { voice.install() }
                while !voice.isInstalled {
                    if case .failed(let m) = voice.state { draft = "VOICE FAILED: " + m; return }
                    try? await Task.sleep(for: .seconds(1))
                }
                let path = FileManager.default.temporaryDirectory.appending(path: name).path
                let result = FileManager.default.temporaryDirectory.appending(path: "voice-result.txt")
                let start = Date()
                do {
                    // First call loads the model (Neural Engine compile on first launch), second is a warm run.
                    let text = try await voice.transcribe(fileAt: path)
                    let first = Date().timeIntervalSince(start)
                    let warmStart = Date()
                    _ = try await voice.transcribe(fileAt: path)
                    let warm = Date().timeIntervalSince(warmStart)
                    draft = text + " [\(Int(first)) s / warm \(String(format: "%.1f", warm)) s]"
                    let mem = String(format: "%.0f MB", Double(os_proc_available_memory()) / 1_048_576)
                    try? "\(text)\nfirst=\(String(format: "%.1f", first))s warm=\(String(format: "%.1f", warm))s availableMemory=\(mem)\n"
                        .write(to: result, atomically: true, encoding: .utf8)
                } catch {
                    draft = "VOICE ERROR: \(error.localizedDescription)"
                    try? "ERROR \(error.localizedDescription)\n".write(to: result, atomically: true, encoding: .utf8)
                }
            }
        }
        .task {
            if let prompt = DebugSeed.pendingPrompt, model.messages.isEmpty {
                DebugSeed.pendingPrompt = nil
                if !prompt.isEmpty { model.send(prompt) }
            }
            // DECKHAND_SEED_IMAGE=1: a made-up error screenshot waits in the composer (the photo picker can't be scripted).
            if ProcessInfo.processInfo.environment["DECKHAND_SEED_IMAGE"] == "1", images.isEmpty {
                let size = CGSize(width: 900, height: 600)
                let sample = UIGraphicsImageRenderer(size: size).image { ctx in
                    UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
                    ("502 Bad Gateway\nnginx/1.24.0" as NSString).draw(in: CGRect(x: 60, y: 220, width: 800, height: 200),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: UIColor.black])
                }
                if let data = sample.pngData(), let jpeg = ImagePrep.jpeg(data) { images = [jpeg] }
            }
        }
        #endif
    }

    private var composer: some View {
        VStack(spacing: 6) {
        if model.thread.planFirst {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard")
                Text("Plan first: the agent only looks and proposes a plan.")
                Spacer()
                Button { model.thread.planFirst = false } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel("Turn off plan first")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.top, 6)
            .accessibilityIdentifier("chat.planFirst")
        }
        if !images.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.offset) { i, data in
                        if let ui = UIImage(data: data) {
                            Image(uiImage: ui).resizable().scaledToFill().frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline))
                                .overlay(alignment: .topTrailing) {
                                    Button { images.remove(at: i) } label: {
                                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .offset(x: 6, y: -6)
                                    .accessibilityLabel("Remove picture")
                                }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
            .accessibilityIdentifier("chat.images")
        }
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button { choosingPhoto = true } label: { Label("Photo", systemImage: "photo") }
                Button { choosingFile = true } label: { Label("File", systemImage: "doc") }
                Divider()
                Toggle(isOn: Binding(get: { model.thread.planFirst }, set: { model.thread.planFirst = $0 })) {
                    Label("Plan first", systemImage: "list.bullet.clipboard")
                }
            } label: {
                Image(systemName: "paperclip").font(.system(size: 20, weight: .medium)).frame(width: 32, height: 36)
            }
            .disabled(upload != nil)
            .accessibilityLabel("Attach a file")
            .accessibilityIdentifier("chat.attach")
            .photosPicker(isPresented: $choosingPhoto, selection: $photoItem, matching: .images)
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
                guard case .success(let url) = result else { return }
                Task { await uploadFile(url) }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task { await uploadPhoto(item) }
            }
            TextField("Tell the agent what to do…", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($composerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.hairline))
            if voice.isInstalled && !model.isRunning {
                MicButton(voice: voice) { text in
                    draft = draft.isEmpty ? text : draft + " " + text
                    composerFocused = true
                }
            }
            if model.isRunning {
                Button { model.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 32)).foregroundStyle(.primary)
                }
                .accessibilityLabel("Stop")
            } else {
                Button {
                    model.send(draft, images: images)
                    draft = ""
                    images = []
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        }
    }

    // MARK: Uploads

    private func uploadPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { uploadError = String(localized: "Couldn't read the photo."); return }
        // With your own key the model sees the picture itself; the CLIs get it as a file on the server.
        if model.thread.engine == .ownKey {
            guard let jpeg = ImagePrep.jpeg(data) else { uploadError = String(localized: "Couldn't read the photo."); return }
            images.append(jpeg)
            uploadError = nil
            composerFocused = true
            return
        }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = f.string(from: Date())
        await send(data, name: "photo-\(stamp).\(ext)")
    }

    private func uploadFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { uploadError = String(localized: "Couldn't read the file."); return }
        await send(data, name: url.lastPathComponent)
    }

    /// Uploads into the task's folder and puts a note into the message, so the agent uses the file right away.
    /// A regression check the agent proposed after an applied fix (incident chats).
    private var checkOffer: (message: UUID, check: Uptime.Check)? {
        guard !model.isRunning, IncidentLinks.check(for: model.thread.id) != nil, let last = model.messages.last,
              last.role == .assistant, last.id != checkHandled, let check = Incident.suggestedCheck(in: last.text) else { return nil }
        return (last.id, check)
    }

    private func addCheck(_ check: Uptime.Check, message: UUID) async {
        var c = check
        c.name += String(localized: " (from an incident)")
        do {
            let conn = try await Connections.shared.connection(for: model.server)
            _ = try await conn.run(Uptime.addCommand(c), timeout: .seconds(60))
            checkAdded = true
            try? await Task.sleep(for: .seconds(1.5))
            checkHandled = message
            checkAdded = false
        } catch {
            model.error = error.localizedDescription
        }
    }

    /// The last action of a server CLI that a house rule stopped (since the user's last message).
    private var ruleBlock: HouseRules.Block? {
        guard !model.isRunning, model.thread.engine.serverCLI != nil else { return nil }
        for m in model.messages.reversed() {
            if m.role == .user, !m.text.isEmpty { return nil }
            for b in m.blocks.reversed() {
                if case .toolResult(let r) = b, let block = HouseRules.block(in: r.content) {
                    return block.fingerprint == dismissedBlock ? nil : block
                }
            }
        }
        return nil
    }

    private func allowOnce(_ block: HouseRules.Block) async {
        guard let fp = block.fingerprint, let cmd = HouseRules.allowOnceCommand(fp) else { return }
        do {
            let conn = try await Connections.shared.connection(for: model.server)
            _ = try await conn.run(cmd, timeout: .seconds(15))
            model.send(String(localized: "I allowed that once. Go ahead and do it now."))
        } catch {
            model.error = error.localizedDescription
        }
    }

    /// The fix the last reply suggests, while nothing runs and the user hasn't applied or dismissed it.
    private var suggestedFix: (message: UUID, commands: String)? {
        guard !model.isRunning, let last = model.messages.last, last.role == .assistant, last.id != dismissedFix,
              let commands = Incident.suggestedFix(in: last.text) else { return nil }
        return (last.id, commands)
    }

    private func send(_ data: Data, name: String) async {
        guard data.count < 500_000_000 else { uploadError = String(localized: "Files up to 500 MB."); return }
        uploadError = nil
        upload = (name, 0)
        defer { upload = nil }
        do {
            let conn = try await Connections.shared.connection(for: model.server)
            let path = try await conn.upload(data, named: name, into: model.thread.workingDirectory) { p in
                Task { @MainActor in if upload != nil { upload?.progress = p } }
            }
            let note = String(localized: "I uploaded a file to \(path).")
            draft = draft.isEmpty ? note + " " : draft + "\n" + note + " "
            composerFocused = true
        } catch {
            uploadError = error.localizedDescription
        }
    }
}

private struct EmptyChatHint: View {
    let server: Server
    let workingDirectory: String
    let engine: Engine
    let pick: (String) -> Void
    private let ideas = [
        String(localized: "Check disk space, memory and failing services"),
        String(localized: "Show me what changed in the last git commit here"),
        String(localized: "Update the system packages and tell me what needs a reboot"),
        String(localized: "Find why nginx returns 502"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrandIcon(brand: engine.brand, size: 44)
            Text("What should happen on \(server.displayName)?").font(.title3.weight(.semibold))
            Text(engine == .ownKey
                 ? "Working in \(workingDirectory). The agent asks before it changes anything."
                 : "Working in \(workingDirectory). Runs with your \(engine.serverCLI?.displayName ?? "") subscription on the server.")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(ideas, id: \.self) { idea in
                Button { pick(idea) } label: {
                    HStack {
                        Text(idea).font(.subheadline).multilineTextAlignment(.leading).foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 24)
    }
}

/// A plan in a reply, as a checklist. While it waits to be run, steps can be ticked off to leave them out.
private struct PlanChecklist: View {
    let steps: [String]
    let model: ChatModel
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(active ? "Plan — tap a step to leave it out" : "Plan", systemImage: "list.bullet.clipboard")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                let skipped = active && model.planSkipped.contains(i)
                Button {
                    if model.planSkipped.contains(i) { model.planSkipped.remove(i) } else { model.planSkipped.insert(i) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if active {
                            Image(systemName: skipped ? "circle" : "checkmark.circle.fill")
                                .foregroundStyle(skipped ? Color.secondary : Theme.accent)
                        } else {
                            Text("\(i + 1)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.accent)
                                .frame(width: 18, alignment: .trailing)
                        }
                        Text(step).font(.subheadline).foregroundStyle(skipped ? .secondary : .primary)
                            .strikethrough(skipped).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!active)
                .accessibilityIdentifier("plan.step.\(i)")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.plan")
    }
}

/// Run the plan (without the unticked steps), adjust it in words, or drop it.
private struct PlanBar: View {
    let total: Int
    let skipped: Int
    let run: () -> Void
    let adjust: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: run) {
                Label(skipped == 0 ? String(localized: "Run plan") : String(localized: "Run \(total - skipped) of \(total) steps"),
                      systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(skipped == total)
            .accessibilityIdentifier("plan.run")
            Button("Adjust", action: adjust).buttonStyle(.bordered).accessibilityIdentifier("plan.adjust")
            Button("Cancel", role: .cancel, action: cancel).buttonStyle(.bordered).accessibilityIdentifier("plan.cancel")
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }
}

/// Where a long task was compacted: the steps above were summarized for the model (they stay visible here).
private struct SummaryDivider: View {
    let summary: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation { open.toggle() } } label: {
                HStack(spacing: 8) {
                    VStack { Divider() }
                    Label("Earlier steps summarized", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(.caption).foregroundStyle(.secondary).fixedSize()
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                    VStack { Divider() }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.summary")
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The agent keeps working from this summary instead of every earlier step, so long tasks fit and cost less.")
                        .font(.caption).foregroundStyle(.secondary)
                    MarkdownText(summary).font(.footnote)
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

private struct MessageView: View {
    let message: Message
    let model: ChatModel

    var body: some View {
        switch message.role {
        case .user:
            let pictures = message.blocks.compactMap { if case .image(_, let d) = $0 { d } else { nil } }
            if !pictures.isEmpty {
                HStack(spacing: 6) {
                    Spacer(minLength: 48)
                    ForEach(Array(pictures.enumerated()), id: \.offset) { _, d in
                        if let ui = UIImage(data: d) {
                            Image(uiImage: ui).resizable().scaledToFit()
                                .frame(maxWidth: pictures.count == 1 ? 220 : 120, maxHeight: pictures.count == 1 ? 220 : 120)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline))
                        }
                    }
                }
                .accessibilityIdentifier("chat.sentImages")
            }
            if !message.text.isEmpty {
                HStack {
                    Spacer(minLength: 48)
                    (PlanMode.isPlanRequest(message.text) ? Text("\(Image(systemName: "list.bullet.clipboard"))  \(PlanMode.unwrap(message.text))") : Text(message.text))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .textSelection(.enabled)
                }
            }
            // Tool results render inside their tool cards.
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let t) where !t.isEmpty:
                        if let steps = PlanMode.steps(in: t) {
                            let parts = PlanMode.around(t)
                            if !parts.before.isEmpty { ReplyText(text: parts.before) }
                            PlanChecklist(steps: steps, model: model, active: model.planOffer?.message == message.id)
                            if !parts.after.isEmpty { ReplyText(text: parts.after) }
                        } else {
                            ReplyText(text: t)
                        }
                    case .thinking(let t, _) where !t.isEmpty:
                        ThinkingView(text: t)
                    case .toolUse(let call):
                        ToolCard(name: call.name, input: call.input, status: status(for: call))
                    default:
                        EmptyView()
                    }
                }
            }
        }
    }

    private func status(for call: ToolCall) -> ChatModel.ToolStatus {
        if let r = model.result(for: call.id) { return .done(r) }
        return model.toolStatus[call.id] ?? .running
    }
}

private struct LiveTurnView: View {
    let model: ChatModel

    private func workingLabel(since start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        let who = model.thread.engine.serverCLI.map { "\($0.displayName) is working" } ?? "Working"
        return s < 60 ? "\(who)… \(s) s" : "\(who)… \(s / 60) min \(s % 60) s"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.liveThinking.isEmpty { ThinkingView(text: model.liveThinking, live: true) }
            if !model.liveText.isEmpty { MarkdownText(model.liveText) }
            ForEach(model.liveTools, id: \.id) { tool in
                ToolCard(
                    name: tool.name,
                    input: (try? JSONValue.parse(tool.input)) ?? .object([:]),
                    status: .streaming)
            }
            if model.liveText.isEmpty && model.liveTools.isEmpty && model.pendingApproval == nil {
                TimelineView(.periodic(from: model.runStartedAt, by: 1)) { context in
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(workingLabel(since: model.runStartedAt, now: context.date))
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct MarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(attributed).textSelection(.enabled)
    }
    private var attributed: AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct ThinkingView: View {
    let text: String
    var live = false
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
        } label: {
            Label(live ? "Thinking…" : "Thought", systemImage: "brain").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct ToolCard: View {
    let name: String
    let input: JSONValue
    let status: ChatModel.ToolStatus
    @State private var expanded = false
    /// Secrets in the command or output are masked until the user taps Show.
    @State private var revealed = false
    @State private var explaining: String?
    @Environment(\.explainFix) private var explainFix

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    if name.contains("__") {
                        Image(Brand.mcp.asset).resizable().renderingMode(.template).scaledToFit()
                            .frame(width: 15, height: 15).foregroundStyle(.secondary).frame(width: 18)
                    } else {
                        Image(systemName: icon).font(.footnote.weight(.medium)).foregroundStyle(.secondary).frame(width: 18)
                    }
                    Text(shown(summary)).font(Theme.mono).lineLimit(expanded ? nil : 1).foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    statusIcon
                }
            }
            .buttonStyle(.plain)
            if expanded, case .done(let result) = status {
                let output = String(result.content.prefix(8000))
                ScrollView(.horizontal) {
                    Text(shown(output))
                        .font(Theme.monoSmall)
                        .foregroundStyle(result.isError ? .red : .secondary)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 280)
                .contextMenu { Button("Explain", systemImage: "sparkle.magnifyingglass") { explaining = output } }
                if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { explaining = output } label: { Label("Explain", systemImage: "sparkle.magnifyingglass").font(.caption) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("toolCard.explain")
                }
            }
            if expanded || hiding(summary) {
                let count = secretCount
                if count > 0 {
                    Button { revealed.toggle() } label: {
                        Label(revealed ? String(localized: "Hide secrets") : String(localized: "\(count) secrets hidden · Show"),
                              systemImage: revealed ? "eye.slash" : "eye")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("toolCard.secrets")
                }
            }
        }
        .sheet(item: Binding(get: { explaining.map { ExplainText(text: $0) } }, set: { explaining = $0?.text })) { e in
            ExplainSheet(text: shown(e.text), context: name == "run_command" ? input["command"]?.stringValue.map { "the command `\($0)`" } : nil, fix: explainFix)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline))
    }

    private var hideSecrets: Bool { AppSettings.shared.hideSecrets }

    private func hiding(_ text: String) -> Bool { hideSecrets && !Secrets.find(in: text).isEmpty }

    private func shown(_ text: String) -> String {
        hideSecrets && !revealed ? Secrets.mask(text) : text
    }

    private var secretCount: Int {
        guard hideSecrets else { return 0 }
        var n = Secrets.find(in: summary).count
        if case .done(let result) = status { n += Secrets.find(in: String(result.content.prefix(8000))).count }
        return n
    }

    @ViewBuilder private var statusIcon: some View {
        switch status {
        case .streaming, .running: ProgressView().controlSize(.small)
        case .waiting: Image(systemName: "hand.raised").foregroundStyle(.orange)
        case .done(let r):
            Image(systemName: r.isError ? "xmark.circle" : "checkmark.circle")
                .foregroundStyle(r.isError ? .red : .green)
        }
    }

    private var icon: String {
        switch name {
        case "run_command": "terminal"
        case "read_file": "doc.text"
        case "write_file": "square.and.pencil"
        case "edit_file": "pencil.line"
        case "list_directory": "folder"
        case "search": "magnifyingglass"
        case "file_change": "doc.badge.ellipsis"
        default: "wrench"
        }
    }

    var summary: String {
        switch name {
        case "run_command": "$ " + (input["command"]?.stringValue ?? "…")
        case "read_file": "read " + (input["path"]?.stringValue ?? "…")
        case "write_file": "write " + (input["path"]?.stringValue ?? "…")
        case "edit_file": "edit " + (input["path"]?.stringValue ?? "…")
        case "list_directory": "ls " + (input["path"]?.stringValue ?? ".")
        case "search": "search " + (input["pattern"]?.stringValue ?? "…")
        case "file_change": "changed " + ((input["paths"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", "))
        default: name.contains("__") ? name.replacingOccurrences(of: "__", with: " · ") : name
        }
    }
}

private struct ApprovalBar: View {
    let approval: ChatModel.PendingApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let rule = approval.rule {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This breaks a house rule").font(.subheadline.weight(.semibold))
                        Text(rule).font(.footnote)
                    }
                } icon: {
                    Image(systemName: "hand.raised.fill")
                }
                .foregroundStyle(.orange)
            } else if let danger = approval.danger {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Careful — this can't easily be undone").font(.subheadline.weight(.semibold))
                        Text(danger).font(.footnote)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
            } else {
                Text("Allow this?").font(.subheadline.weight(.semibold))
            }
            ToolCard(name: approval.call.name, input: approval.call.input, status: .waiting)
            if approval.call.name == "edit_file" || approval.call.name == "write_file" {
                EditPreview(input: approval.call.input)
            }
            HStack {
                Button(role: .destructive) { approval.respond(.deny(reason: nil)) } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { approval.respond(.allow) } label: {
                    Text(approval.rule != nil ? String(localized: "Allow once") : approval.danger == nil ? String(localized: "Allow") : String(localized: "Run Anyway")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(approval.danger == nil ? Theme.accent : .red)
            }
            .controlSize(.large)
        }
        .padding(12)
    }
}

private struct EditPreview: View {
    let input: JSONValue
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let old = input["old_string"]?.stringValue {
                    ForEach(Array(old.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) {
                        Text("- " + $0.element).foregroundStyle(.red)
                    }
                }
                let new = input["new_string"]?.stringValue ?? input["content"]?.stringValue ?? ""
                ForEach(Array(new.split(separator: "\n", omittingEmptySubsequences: false).prefix(200).enumerated()), id: \.offset) {
                    Text("+ " + $0.element).foregroundStyle(.green)
                }
            }
            .font(Theme.monoSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Tap to talk, tap again to stop; the transcript lands in the message field.
private struct MicButton: View {
    let voice: VoiceInput
    let onText: (String) -> Void
    @State private var error: String?

    var body: some View {
        Button {
            Task {
                if voice.isRecording {
                    do {
                        let text = try await voice.stopAndTranscribe()
                        if !text.isEmpty { onText(text) }
                    } catch {
                        self.error = error.localizedDescription
                    }
                } else if !(await voice.startRecording()) {
                    error = "Allow microphone access for Deckhand in Settings."
                }
            }
        } label: {
            ZStack {
                if voice.isTranscribing {
                    ProgressView()
                } else {
                    Image(systemName: voice.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(voice.isRecording ? .red : Theme.accent)
                        .scaleEffect(voice.isRecording ? 1 + CGFloat(voice.level) * 0.25 : 1)
                        .animation(.easeOut(duration: 0.08), value: voice.level)
                }
            }
            .frame(width: 32, height: 32)
        }
        .disabled(voice.isTranscribing)
        .accessibilityLabel(voice.isRecording ? "Stop recording" : "Dictate")
        .alert("Voice input", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}

/// An assistant reply; tokens, keys and passwords in it stay masked until the user taps Show.
struct ReplyText: View {
    let text: String
    @State private var revealed = false

    var body: some View {
        let count = AppSettings.shared.hideSecrets ? Secrets.find(in: text).count : 0
        VStack(alignment: .leading, spacing: 6) {
            MarkdownView(count > 0 && !revealed ? Secrets.mask(text) : text)
            if count > 0 {
                Button { revealed.toggle() } label: {
                    Label(revealed ? String(localized: "Hide secrets") : String(localized: "\(count) secrets hidden · Show"),
                          systemImage: revealed ? "eye.slash" : "eye")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("reply.secrets")
            }
        }
    }
}

/// Pictures for the model: at most 1568 px on the longer side (what Claude uses at full detail), JPEG.
enum ImagePrep {
    static func jpeg(_ data: Data, maxSide: CGFloat = 1568) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.8)
    }
}

struct ExplainText: Identifiable { let text: String; var id: Int { text.hashValue } }
