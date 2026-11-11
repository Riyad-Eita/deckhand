import DeckhandCore
import LocalAuthentication
import SwiftUI
import UIKit

/// A risky action an agent wants to run on a server, opened from a lock-screen push: Face ID, then Allow or Deny.
/// The answer goes back to the server over ntfy (`<topic>-reply`), where the waiting check picks it up.
struct ApproveSheet: View {
    let link: AppRouter.ApprovalLink
    let server: Server?
    @Environment(\.dismiss) private var dismiss
    @State private var sending = false
    @State private var sent: Bool?
    @State private var error: String?

    private var replyTopic: String? {
        if let server, let ask = HouseRulesStore.rules(for: server)?.ask { return ask.replyTopic }
        let topic = AppSettings.shared.ntfyTopicURL
        return topic.isEmpty ? nil : topic.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "-reply"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(link.who.isEmpty ? String(localized: "An agent") : link.who) wants to run this on \(server?.displayName ?? String(localized: "your server")):")
                                .font(.subheadline)
                            Text(link.command).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                } footer: {
                    Text("This can't easily be undone. If you don't answer, the server says no by itself.")
                }
                if let error { ProblemView(message: error, compact: true) }
                if let sent {
                    Label(sent ? String(localized: "Allowed. The agent continues.") : String(localized: "Denied. The agent was told no."),
                          systemImage: sent ? "checkmark.circle.fill" : "hand.raised.fill")
                        .foregroundStyle(sent ? .green : .orange)
                } else {
                    Section {
                        Button(role: .destructive) { Task { await answer(true) } } label: {
                            HStack { Text("Allow with Face ID"); Spacer(); if sending { ProgressView() } }
                        }
                        .disabled(sending || replyTopic == nil)
                        .accessibilityIdentifier("approve.allow")
                        Button("Deny") { Task { await answer(false) } }.disabled(sending || replyTopic == nil)
                            .accessibilityIdentifier("approve.deny")
                    }
                }
            }
            .navigationTitle("Allow this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(sent == nil ? "Later" : "Done") { dismiss() } } }
        }
    }

    private func answer(_ allow: Bool) async {
        if allow {
            var skip = false
            #if DEBUG
            skip = ProcessInfo.processInfo.environment["DECKHAND_SEED_SKIPAUTH"] == "1"
            #endif
            if !skip {
                let ctx = LAContext()
                guard (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Allow a risky action"))) == true else { return }
            }
        }
        guard let topic = replyTopic, let url = URL(string: topic) else { return }
        sending = true
        defer { sending = false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data(HouseRules.answer(allow, fingerprint: link.fingerprint, device: UIDevice.current.name).utf8)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 300 else { throw URLError(.badServerResponse) }
            sent = allow
        } catch {
            self.error = error.localizedDescription
        }
    }
}
