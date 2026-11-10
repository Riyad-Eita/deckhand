import DeckhandCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import os

struct AgentChatView: View {
    @State private var model: ChatModel
    @State private var draft = ""
    @State private var voice = VoiceInput.shared
    @FocusState private var composerFocused: Bool
    @State private var browsing: BrowserTarget?
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var choosingFile = false
    @State private var upload: (name: String, progress: Double)?
    @State private var uploadError: String?

    init(thread: ChatThread, server: Server) {
        _model = State(initialValue: ChatModel.model(for: thread, server: server))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.messages.isEmpty && !model.isRunning {
                        EmptyChatHint(server: model.server, workingDirectory: model.thread.workingDirectory, engine: model.thread.engine) { draft = $0; composerFocused = true }
                    }
                    ForEach(model.messages) { message in
                        MessageView(message: message, model: model)
                    }
                    if model.isRunning { LiveTurnView(model: model) }
                    if let notice = model.notice {
                        Label(notice, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
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
                        Text("\(model.thread.engine.shortTitle) · \(model.thread.workingDirectory)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                .frame(maxWidth: 260)
            }
        }
        // Links to the server's localhost (http://localhost:3000) open through an SSH tunnel.
        .environment(\.openURL, OpenURLAction { url in
            guard let port = ListeningPorts.localPort(in: url) else { return .systemAction }
            browsing = BrowserTarget(port: port, path: url.path.isEmpty ? "/" : url.path + (url.query.map { "?" + $0 } ?? ""))
            return .handled
        })
        .sheet(item: $browsing) { BrowserSheet(server: model.server, port: $0.port, path: $0.path) }
        .onAppear { AppRouter.shared.visibleThread = model.thread.id }
        .onDisappear { if AppRouter.shared.visibleThread == model.thread.id { AppRouter.shared.visibleThread = nil } }
        .task {
            model.resumeIfNeeded()
            if let prompt = PendingPrompt.take(for: model.thread.id), model.messages.isEmpty { model.send(prompt) }
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
                model.send(prompt)
            }
        }
        #endif
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button { choosingPhoto = true } label: { Label("Photo", systemImage: "photo") }
                Button { choosingFile = true } label: { Label("File", systemImage: "doc") }
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
                    model.send(draft)
                    draft = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Uploads

    private func uploadPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { uploadError = String(localized: "Couldn't read the photo."); return }
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

private struct MessageView: View {
    let message: Message
    let model: ChatModel

    var body: some View {
        switch message.role {
        case .user:
            if !message.text.isEmpty {
                HStack {
                    Spacer(minLength: 48)
                    Text(message.text)
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
                        MarkdownView(t)
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
                    Text(summary).font(Theme.mono).lineLimit(expanded ? nil : 1).foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    statusIcon
                }
            }
            .buttonStyle(.plain)
            if expanded, case .done(let result) = status {
                ScrollView(.horizontal) {
                    Text(result.content.prefix(8000))
                        .font(Theme.monoSmall)
                        .foregroundStyle(result.isError ? .red : .secondary)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline))
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
            if let danger = approval.danger {
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
                    Text(approval.danger == nil ? "Allow" : "Run Anyway").frame(maxWidth: .infinity)
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
