import DeckhandCore
import SwiftUI

/// The same question to two models at once: both answers, how long each took, the tokens and the cost — and which
/// model "Auto" would have picked.
struct CompareModelsView: View {
    @State var prompt: String
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var left = ""
    @State private var right = ""
    @State private var results: [String: Run] = [:]
    @State private var task: Task<Void, Never>?

    struct Run: Equatable {
        var text = ""
        var seconds: Double?
        var usage: Usage?
        var error: String?
        var running = true
    }

    private var candidates: [ModelRouter.Candidate] { settings.routerCandidates }
    private var autoPick: (ModelRouter.TaskKind, ModelRouter.Candidate?) {
        let kind = ModelRouter.classify(prompt)
        return (kind, ModelRouter.pick(for: kind, length: prompt.count, among: candidates))
    }

    var body: some View {
        List {
            Section {
                TextField("Ask both models…", text: $prompt, axis: .vertical)
                    .lineLimit(2...8)
                    .accessibilityIdentifier("compare.prompt")
                picker("First model", selection: $left).accessibilityIdentifier("compare.left")
                picker("Second model", selection: $right).accessibilityIdentifier("compare.right")
                Button {
                    if task != nil { task?.cancel(); task = nil } else { run() }
                } label: {
                    Label(task != nil ? String(localized: "Stop") : String(localized: "Compare"),
                          systemImage: task != nil ? "stop.fill" : "square.split.2x1")
                        .font(.headline)
                }
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || left.isEmpty || right.isEmpty)
                .accessibilityIdentifier("compare.run")
            } footer: {
                let (kind, pick) = autoPick
                if let pick, !prompt.isEmpty {
                    Text("Auto would treat this as “\(kind.title)” and pick \(pick.model).")
                }
            }
            if candidates.isEmpty {
                Section { Text("Add an API key in Settings, or set up your own model on a server, to compare models.").foregroundStyle(.secondary) }
            }
            ForEach([left, right].filter { !$0.isEmpty }, id: \.self) { id in
                if let run = results[id], let c = candidates.first(where: { $0.id == id }) {
                    Section { answer(run, candidate: c) } header: { Text(c.model) }
                }
            }
        }
        .navigationTitle("Compare models")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .onAppear {
            guard left.isEmpty else { return }
            // Defaults: the cheapest and the most capable of the user's models.
            let price = { (c: ModelRouter.Candidate) in c.price?.output ?? .greatestFiniteMagnitude }
            left = candidates.min { (price($0), $0.tier.rawValue) < (price($1), $1.tier.rawValue) }?.id ?? ""
            right = candidates.filter { $0.id != left }
                .max { ($0.tier.rawValue, $0.price?.output ?? -1) < ($1.tier.rawValue, $1.price?.output ?? -1) }?.id ?? ""
        }
        .onDisappear { task?.cancel() }
    }

    private func picker(_ title: LocalizedStringKey, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(candidates) { c in
                Text(c.model).tag(c.id)
            }
        }
    }

    @ViewBuilder
    private func answer(_ run: Run, candidate c: ModelRouter.Candidate) -> some View {
        if let error = run.error {
            ProblemView(message: error, compact: true)
        } else if run.text.isEmpty && run.running {
            HStack(spacing: 8) { ProgressView(); Text("Thinking…").foregroundStyle(.secondary) }
        } else {
            ReplyText(text: run.text)
                .accessibilityIdentifier("compare.answer")
        }
        if run.seconds != nil || run.usage != nil {
        HStack(spacing: 12) {
            if let s = run.seconds { Label(String(format: "%.1f s", s), systemImage: "clock") }
            if let u = run.usage {
                Label("\(u.inputTokens + u.cacheReadTokens) → \(u.outputTokens)", systemImage: "number")
                Label(c.price.map { ModelPrice.format($0.cost(u)) } ?? String(localized: "price unknown"), systemImage: "dollarsign.circle")
                    .accessibilityIdentifier("compare.cost")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        }
    }

    private func run() {
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let picks = [left, right].compactMap { id in candidates.first { $0.id == id } }
        results = Dictionary(uniqueKeysWithValues: picks.map { ($0.id, Run()) })
        task = Task {
            await withTaskGroup(of: Void.self) { group in
                for c in picks {
                    group.addTask { await stream(c, question) }
                }
            }
            task = nil
        }
    }

    private func stream(_ c: ModelRouter.Candidate, _ question: String) async {
        let config = settings.providerConfig(kind: c.provider, model: c.model)
        let provider = AppProviders.make(config)
        let request = ChatRequest(system: PlainChatModel.system, messages: [.user(question)], tools: [], maxTokens: 8_000)
        let start = Date()
        do {
            for try await event in provider.stream(request) {
                switch event {
                case .textDelta(let t): results[c.id]?.text += t
                case .completed(let m, _, let u):
                    results[c.id]?.text = m.text
                    results[c.id]?.usage = u
                default: break
                }
            }
            results[c.id]?.seconds = Date().timeIntervalSince(start)
        } catch {
            if !Task.isCancelled { results[c.id]?.error = error.localizedDescription }
        }
        results[c.id]?.running = false
    }
}
