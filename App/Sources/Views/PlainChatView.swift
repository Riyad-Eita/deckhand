import DeckhandCore
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// A shell for chats without a server: there are no tools, so nothing ever runs.
struct NoShell: RemoteShell {
    func run(_ command: String, timeout: Duration) async throws -> CommandResult { CommandResult(stdout: "", stderr: "No server", exitCode: 1) }
}

/// A plain chat with any of your models: streaming answers, pictures and text files, and a model switch that keeps
/// the conversation.
@MainActor
@Observable
final class PlainChatModel {
    let thread: ChatThread
    private(set) var messages: [Message]
    private(set) var liveText = ""
    private(set) var isRunning = false
    var error: String?
    private var task: Task<Void, Never>?

    init(thread: ChatThread) {
        self.thread = thread
        self.messages = thread.messages
    }

    /// Claude Code or Codex on one of the user's servers answers instead of an API model (their own plan).
    var plan: (cli: ServerCLI, server: UUID)? {
        guard let raw = thread.chatProviderRaw, raw.hasPrefix(Self.planPrefix), let cli = ServerCLI(rawValue: String(raw.dropFirst(Self.planPrefix.count))),
              let id = thread.chatHostRaw.flatMap(UUID.init(uuidString:)) else { return nil }
        return (cli, id)
    }
    static let planPrefix = "plan."

    func usePlan(_ cli: ServerCLI, server: UUID) {
        if plan.map({ $0.cli != cli || $0.server != server }) ?? true { thread.cliSessionID = nil }
        thread.chatProviderRaw = Self.planPrefix + cli.rawValue
        thread.chatHostRaw = server.uuidString
        thread.chatModel = nil
    }

    var provider: ProviderKind {
        thread.chatProviderRaw.flatMap(ProviderKind.init(rawValue:)) ?? AppSettings.shared.providerKind
    }
    var model: String { thread.chatModel ?? AppSettings.shared.defaultModel(for: provider) }
    var isAuto: Bool { thread.chatModel == ModelRouter.auto }
    /// What "Auto" chose for the last message.
    private(set) var lastRoute: (kind: ModelRouter.TaskKind, pick: ModelRouter.Candidate)?

    func useAuto() {
        if plan != nil { thread.chatProviderRaw = nil; thread.chatHostRaw = nil; thread.cliSessionID = nil }
        thread.chatModel = ModelRouter.auto
    }

    func use(_ kind: ProviderKind, model: String) {
        if plan != nil { thread.cliSessionID = nil }
        thread.chatProviderRaw = kind.rawValue
        thread.chatModel = model
    }

    static let system = """
    You are a helpful assistant. The user is on their phone: lead with the answer, keep it short unless they ask \
    for detail, and use Markdown sparingly (lists, code blocks and tables are fine).
    """

    func send(_ text: String, images: [Data] = [], files: [(name: String, text: String)] = []) {
        var asked = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if asked.isEmpty && !images.isEmpty { asked = String(localized: "What do you see here?") }
        guard !asked.isEmpty || !files.isEmpty, !isRunning else { return }
        if let plan {
            sendWithPlan(plan, asked: asked, images: images, files: files)
            return
        }
        var kind = provider, chosen = model
        if isAuto {
            let task = ModelRouter.classify(asked + files.map(\.text).joined(), images: images.count)
            let length = (messages.map(\.text) + [asked] + files.map(\.text)).reduce(0) { $0 + $1.count }
            guard let pick = ModelRouter.pick(for: task, length: length, among: AppSettings.shared.routerCandidates) else {
                error = LLMError.missingAPIKey.localizedDescription
                return
            }
            kind = pick.provider; chosen = pick.model
            lastRoute = (task, pick)
        }
        let config = AppSettings.shared.providerConfig(kind: kind, model: chosen)
        guard !config.model.isEmpty, !config.apiKey.isEmpty || kind == .custom else {
            error = LLMError.missingAPIKey.localizedDescription
            return
        }
        if case .stop(let why) = Spend.check(task: Spend.total(messages, price: AppSettings.shared.price(for:)).cost,
                                            day: AppSettings.shared.spentToday, limits: AppSettings.shared.spendLimits) {
            error = why
            return
        }
        error = nil
        let attached = files.map { "\($0.name):\n```\n\($0.text)\n```" }
        let user = Message(role: .user, blocks: images.map { .image(mediaType: "image/jpeg", data: $0) }
            + (attached + [asked]).filter { !$0.isEmpty }.map { .text($0) })
        let history = ChatModel.history(messages, start: thread.historyStart, summary: thread.historySummary)
        let start = thread.historyStart
        if messages.isEmpty {
            thread.title = String((asked.isEmpty ? files.first?.name ?? "" : asked).prefix(60))
            if !asked.isEmpty {
                let request = asked, thread = thread
                Task { if let t = await QuickAI.title(for: request) { thread.title = t } }
            }
        }
        messages.append(user)
        persist()
        isRunning = true
        task = Task {
            do {
                let agent = Agent(provider: AppProviders.make(config), shell: NoShell(), tools: [], policy: .auto,
                                  system: Self.system, approve: { _ in .deny(reason: nil) })
                for try await event in agent.run(history: history, userMessage: user) {
                    switch event {
                    case .textDelta(let t): liveText += t
                    case .message(var m):
                        if m.role == .assistant { m.model = chosen }
                        messages.append(m)
                        liveText = ""
                        persist()
                    case .usage(let u):
                        if let i = messages.lastIndex(where: { $0.role == .assistant }) {
                            var total = messages[i].usage ?? Usage()
                            total.inputTokens += u.inputTokens; total.outputTokens += u.outputTokens; total.cacheReadTokens += u.cacheReadTokens
                            messages[i].usage = total
                            AppSettings.shared.recordSpend(AppSettings.shared.price(for: chosen)?.cost(u) ?? 0)
                            persist()
                        }
                    case .compacted(let summary, let dropped):
                        thread.historySummary = summary
                        thread.historyStart = min(start + dropped, messages.count)
                    case .finished(.refusal): error = String(localized: "The model declined this request.")
                    case .finished(.maxTokens): error = String(localized: "The reply hit the output limit.")
                    default: break
                    }
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            liveText = ""
            isRunning = false
            persist()
        }
    }

    /// The folder plan chats run in on the server: empty, and the CLI may only read.
    static let planFolder = "~/.deckhand/chat"

    /// One turn through Claude Code or Codex on the server, signed in with the user's plan. The CLI keeps the
    /// conversation (its session), so later turns only send the new message.
    private func sendWithPlan(_ plan: (cli: ServerCLI, server: UUID), asked: String, images: [Data], files: [(name: String, text: String)]) {
        guard images.isEmpty else {
            error = String(localized: "Pictures need a model with an API key. Pick one from the title.")
            return
        }
        let servers = (try? thread.modelContext?.fetch(FetchDescriptor<Server>())) ?? []
        guard let server = servers.first(where: { $0.id == plan.server }) else {
            error = String(localized: "The server for this chat was removed. Pick another one from the title.")
            return
        }
        error = nil
        let attached = files.map { "\($0.name):\n```\n\($0.text)\n```" }
        let user = Message(role: .user, blocks: (attached + [asked]).filter { !$0.isEmpty }.map { .text($0) })
        var prompt = (attached + [asked]).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if thread.cliSessionID == nil {
            // A new session: how to answer, and the conversation so far when the chat started with another model.
            let earlier = messages.suffix(12).map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n\n")
            prompt = Self.system + " Answer from what you know; don't read or run anything on this server unless asked.\n\n"
                + (earlier.isEmpty ? "" : "The conversation so far:\n\n\(earlier)\n\n") + prompt
        }
        if messages.isEmpty {
            thread.title = String((asked.isEmpty ? files.first?.name ?? "" : asked).prefix(60))
            if !asked.isEmpty {
                let request = asked, thread = thread
                Task { if let t = await QuickAI.title(for: request) { thread.title = t } }
            }
        }
        messages.append(user)
        persist()
        isRunning = true
        let label = "\(plan.cli.displayName) · \(server.displayName)"
        let options = AppSettings.shared.cliOptions(for: plan.cli)
        task = Task {
            do {
                let shell = try await Connections.shared.connection(for: server)
                _ = try? await shell.run("mkdir -p \(Self.planFolder) && chmod 700 \(Self.planFolder)", timeout: .seconds(15))
                let events = ServerCLIRun.run(plan.cli, shell: shell, prompt: prompt, workingDirectory: Self.planFolder,
                                              sessionID: thread.cliSessionID, access: .readOnly, options: options)
                for try await event in events {
                    switch event {
                    case .textDelta(let t): liveText += t
                    case .sessionStarted(let id): thread.cliSessionID = id
                    case .message(var m):
                        guard m.role == .assistant, !m.text.isEmpty else { continue }
                        m.model = label
                        messages.append(m)
                        liveText = ""
                        persist()
                    default: break
                    }
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            liveText = ""
            isRunning = false
            persist()
        }
    }

    func stop() { task?.cancel() }

    private func persist() { thread.messages = messages }
}

struct PlainChatView: View {
    let thread: ChatThread
    @State private var model: PlainChatModel
    @State private var draft = ""
    @State private var images: [Data] = []
    @State private var files: [(name: String, text: String)] = []
    @State private var photo: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var choosingFile = false
    @FocusState private var focused: Bool
    @State private var comparing = false
    @Query(sort: \Server.name) private var servers: [Server]
    private var settings: AppSettings { .shared }

    /// "Claude Code · web-1" for a plan chat, the model otherwise.
    private var modelLabel: String {
        if let plan = model.plan {
            return "\(plan.cli.displayName) · \(servers.first { $0.id == plan.server }?.displayName ?? "?")"
        }
        return model.isAuto ? String(localized: "Auto") : model.model
    }

    init(thread: ChatThread) {
        self.thread = thread
        _model = State(initialValue: PlainChatModel(thread: thread))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.messages.isEmpty && !model.isRunning {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ask anything").font(.title3.weight(.semibold))
                            Text(model.plan != nil
                                 ? String(localized: "\(modelLabel) answers with your own plan — no API key. It runs in an empty folder on that server and only reads. Switch any time from the title.")
                                 : model.isAuto
                                 ? String(localized: "Each message goes to the cheapest of your models that's good enough for it. No server, no tools — pick a fixed model any time from the title.")
                                 : String(localized: "A plain chat with \(model.model). No server, no tools — switch the model any time from the title."))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.top, 24)
                    }
                    ForEach(model.messages) { m in bubble(m) }
                    if model.isRunning {
                        if model.liveText.isEmpty {
                            HStack(spacing: 8) { ProgressView(); Text("Thinking…").foregroundStyle(.secondary) }
                        } else {
                            ReplyText(text: model.liveText)
                        }
                    }
                    if let error = model.error { ProblemView(message: error, compact: true) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.messages.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.liveText) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) { composer.background(.bar) }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Menu {
                    Button {
                        model.useAuto()
                    } label: {
                        if model.isAuto { Label("Auto — cheapest that fits", systemImage: "checkmark") } else { Label("Auto — cheapest that fits", systemImage: "wand.and.stars") }
                    }
                    .accessibilityIdentifier("chat.model.auto")
                    Button { comparing = true } label: { Label("Compare two models…", systemImage: "square.split.2x1") }
                        .accessibilityIdentifier("chat.compare")
                    if !servers.isEmpty {
                        Section("Your plan · no API key") {
                            ForEach(servers) { server in
                                ForEach(ServerCLI.allCases.reversed()) { cli in
                                    Button {
                                        model.usePlan(cli, server: server.id)
                                    } label: {
                                        let title = String(localized: "\(cli.displayName) on \(server.displayName)")
                                        if model.plan.map({ $0.cli == cli && $0.server == server.id }) == true { Label(title, systemImage: "checkmark") } else { Text(title) }
                                    }
                                    .accessibilityIdentifier("chat.plan.\(cli.rawValue)")
                                }
                            }
                        }
                    }
                    ForEach(settings.chatProviders) { kind in
                        Section(kind.displayName) {
                            let models = Array(Set(settings.modelChoices(for: kind).filter(\.recommended).map(\.id) + [settings.defaultModel(for: kind)])).filter { !$0.isEmpty }.sorted()
                            ForEach(models, id: \.self) { m in
                                Button {
                                    model.use(kind, model: m)
                                } label: {
                                    if model.plan == nil && !model.isAuto && kind == model.provider && m == model.model { Label(m, systemImage: "checkmark") } else { Text(m) }
                                }
                            }
                        }
                    }
                } label: {
                    VStack(spacing: 1) {
                        Text(thread.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 3) {
                            Text(modelLabel).font(.caption2).foregroundStyle(.secondary)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 240)
                }
                .accessibilityIdentifier("chat.model")
            }
        }
        .appSheet(isPresented: $comparing) {
            NavigationStack { CompareModelsView(prompt: model.messages.last(where: { $0.role == .user })?.text ?? draft) }
        }
        #if DEBUG
        .task {
            if let prompt = ProcessInfo.processInfo.environment["DECKHAND_SEED_CHAT_PROMPT"], model.messages.isEmpty { model.send(prompt) }
        }
        #endif
    }

    @ViewBuilder private func bubble(_ m: Message) -> some View {
        switch m.role {
        case .user:
            let pictures = m.blocks.compactMap { if case .image(_, let d) = $0 { d } else { nil } }
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(Array(pictures.enumerated()), id: \.offset) { _, d in
                    if let ui = UIImage(data: d) {
                        Image(uiImage: ui).resizable().scaledToFit().frame(maxWidth: 220, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline))
                    }
                }
                ForEach(Array(m.blocks.enumerated()), id: \.offset) { _, b in
                    if case .text(let t) = b, !t.isEmpty {
                        let isFile = t.contains(":\n```\n")
                        if isFile {
                            UserBubble(text: String(t.prefix { $0 != ":" }), icon: "doc.text", dimmed: true)
                        } else {
                            UserBubble(text: t)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 48)
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                ReplyText(text: m.text)
                if let name = m.model { ModelCaption(model: name, usage: m.usage) }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if !images.isEmpty || !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { i, d in
                            if let ui = UIImage(data: d) {
                                Image(uiImage: ui).resizable().scaledToFill().frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline))
                                    .overlay(alignment: .topTrailing) { remove { images.remove(at: i) } }
                            }
                        }
                        ForEach(Array(files.enumerated()), id: \.offset) { i, f in
                            Label(f.name, systemImage: "doc.text").font(.caption).lineLimit(1)
                                .padding(.horizontal, 10).frame(height: 56)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline))
                                .overlay(alignment: .topTrailing) { remove { files.remove(at: i) } }
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 8)
                }
                .accessibilityIdentifier("plainchat.attachments")
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { choosingPhoto = true } label: { Label("Photo", systemImage: "photo") }
                    Button { choosingFile = true } label: { Label("Text file", systemImage: "doc.text") }
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 20, weight: .medium)).frame(width: 32, height: 36)
                }
                .accessibilityLabel("Attach")
                .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
                .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.text, .sourceCode, .json, .xml, .commaSeparatedText]) { r in
                    guard case .success(let url) = r else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url), data.count < 300_000, let text = String(data: data, encoding: .utf8) else {
                        model.error = String(localized: "Text files up to 300 KB.")
                        return
                    }
                    files.append((url.lastPathComponent, text))
                }
                .onChange(of: photo) { _, item in
                    guard let item else { return }
                    photo = nil
                    Task {
                        if let d = try? await item.loadTransferable(type: Data.self), let jpeg = ImagePrep.jpeg(d) { images.append(jpeg) }
                    }
                }
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.hairline))
                    .accessibilityIdentifier("plainchat.input")
                if model.isRunning {
                    Button { model.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 32)).foregroundStyle(.primary) }
                        .accessibilityLabel("Stop")
                } else {
                    Button {
                        model.send(draft, images: images, files: files)
                        draft = ""; images = []; files = []
                    } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)) }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty && files.isEmpty)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func remove(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
        }
        .offset(x: 6, y: -6)
        .accessibilityLabel("Remove")
    }
}

/// Under an answer: which model wrote it and what it cost.
struct ModelCaption: View {
    let model: String
    let usage: Usage?
    private var settings: AppSettings { .shared }

    var body: some View {
        let price = settings.price(for: model)
        HStack(spacing: 4) {
            Image(systemName: "cpu").font(.system(size: 9))
            Text(model)
            if let usage, usage.outputTokens > 0 {
                Text("·")
                if let price { Text(ModelPrice.format(price.cost(usage))) } else { Text("\(usage.inputTokens + usage.cacheReadTokens) in, \(usage.outputTokens) out") }
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.caption")
    }
}
