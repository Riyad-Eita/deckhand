import DeckhandCore
import SwiftUI

/// What does this output mean? Explanation from the on-device model (or your key), labelled with where it came
/// from, and "Fix it" to hand it to an agent.
struct ExplainSheet: View {
    let text: String
    var context: String? = nil
    /// Starts a task with the fix prompt (nil: no "Fix it").
    var fix: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var answer: (text: String, source: QuickAI.Source)?
    @State private var error: String?
    @State private var unavailable = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // The end matters most (errors come last).
                    Text(Explain.tail(Explain.stripANSI(text), lines: 6)).font(Theme.monoSmall).foregroundStyle(.secondary)
                        .lineLimit(8).truncationMode(.head)
                } header: { Text("Output") }
                Section {
                    if let answer {
                        ReplyText(text: answer.text).accessibilityIdentifier("explain.answer")
                    } else if unavailable {
                        Text("Explanations need Apple Intelligence on this iPhone or a model key in Settings.").foregroundStyle(.secondary)
                    } else if let error {
                        ProblemView(message: error, compact: true)
                    } else {
                        HStack(spacing: 8) { ProgressView(); Text("Reading it…").foregroundStyle(.secondary) }
                    }
                } header: {
                    Text("What it means")
                } footer: {
                    if let answer {
                        switch answer.source {
                        case .onDevice: Label("On this iPhone · free, nothing leaves the device", systemImage: "lock.iphone")
                        case .key(let model): Label("With your key · \(model)", systemImage: "key.horizontal")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let fix, let answer {
                    Button {
                        fix(Explain.fixPrompt(text, explanation: answer.text, context: context))
                        dismiss()
                    } label: {
                        Label("Fix it with an agent", systemImage: "wrench.and.screwdriver").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .accessibilityIdentifier("explain.fix")
                }
            }
            .navigationTitle("Explain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        do {
            if let r = try await QuickAI.run(Explain.instructions, Explain.prompt(text, context: context)) {
                answer = r
            } else {
                unavailable = true
            }
        } catch { self.error = error.localizedDescription }
    }
}

/// Lets views deep inside a chat (tool cards) hand a fix prompt to the chat they're in.
private struct ExplainFixKey: EnvironmentKey { nonisolated(unsafe) static let defaultValue: ((String) -> Void)? = nil }
extension EnvironmentValues {
    var explainFix: ((String) -> Void)? {
        get { self[ExplainFixKey.self] }
        set { self[ExplainFixKey.self] = newValue }
    }
}
