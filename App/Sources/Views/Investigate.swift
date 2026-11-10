import SwiftData
import SwiftUI

/// "Investigate with an agent" from any screen: pick an engine, then the task opens right here
/// (back returns to where the question came from). Works on pushed screens, where a dialog on the
/// server screen underneath could not appear.
struct InvestigateModifier: ViewModifier {
    let server: Server
    @Binding var prompt: String?
    @Environment(\.modelContext) private var context
    @State private var thread: ChatThread?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Investigate with",
                isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }),
                titleVisibility: .visible
            ) {
                ForEach([Engine.claudeCode, .codex, .ownKey]) { engine in
                    Button(engine.title) { start(engine) }
                }
            } message: {
                Text("The agent looks into it and asks before it changes anything.")
            }
            .navigationDestination(item: $thread) { AgentChatView(thread: $0, server: server) }
    }

    private func start(_ engine: Engine) {
        guard let text = prompt else { return }
        let t = ChatThread(server: server, workingDirectory: server.recentDirectories.first ?? server.workingDirectory, engine: engine)
        context.insert(t)
        PendingPrompt.set(text, for: t.id)
        prompt = nil
        thread = t
    }
}

extension View {
    func investigate(on server: Server, prompt: Binding<String?>) -> some View {
        modifier(InvestigateModifier(server: server, prompt: prompt))
    }
}
