import DeckhandCore
import SwiftUI

struct AgentChatView: View {
    @State private var model: ChatModel
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    init(thread: ChatThread, server: Server) {
        _model = State(initialValue: ChatModel(thread: thread, server: server))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.messages.isEmpty && !model.isRunning {
                        EmptyChatHint(server: model.server) { draft = $0; composerFocused = true }
                    }
                    ForEach(model.messages) { message in
                        MessageView(message: message, model: model)
                    }
                    if model.isRunning { LiveTurnView(model: model) }
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
                composer
            }
            .background(.bar)
        }
        .navigationTitle(model.thread.title)
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
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
            TextField("Tell the agent what to do…", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($composerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.background, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary))
            if model.isRunning {
                Button { model.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 32))
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
}

private struct EmptyChatHint: View {
    let server: Server
    let pick: (String) -> Void
    private let ideas = [
        "Check disk space, memory and failing services",
        "Show me what changed in the last git commit here",
        "Update the system packages and tell me what needs a reboot",
        "Find why nginx returns 502",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What should happen on \(server.displayName)?").font(.title3.weight(.semibold))
            Text("The agent works in \(server.workingDirectory) and asks before it changes anything.")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(ideas, id: \.self) { idea in
                Button { pick(idea) } label: {
                    Text(idea).font(.subheadline).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
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
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.signal.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                        .textSelection(.enabled)
                }
            }
            // Tool results render inside their tool cards.
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let t) where !t.isEmpty:
                        MarkdownText(t)
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
                ProgressView().padding(.vertical, 4)
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
                    Image(systemName: icon).foregroundStyle(Theme.signal).frame(width: 18)
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
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
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
        default: name
        }
    }
}

private struct ApprovalBar: View {
    let approval: ChatModel.PendingApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow this?").font(.subheadline.weight(.semibold))
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
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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
