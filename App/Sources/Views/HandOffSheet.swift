import DeckhandCore
import SwiftData
import SwiftUI

/// "Continue on a computer": the command that opens this Claude Code / Codex session in a terminal on another
/// machine, to copy or share — and on the Mac, to open in Terminal right away.
struct HandOffSheet: View {
    let thread: ChatThread
    let server: Server
    let cli: ServerCLI
    @Query private var servers: [Server]
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var openFailed = false

    private var command: String? {
        guard let session = thread.cliSessionID else { return nil }
        let jump = server.jumpHostID.flatMap { id in servers.first { $0.id == id } }
        return HandOff.command(cli: cli, server: .init(host: server.host, port: server.port, user: server.username),
                               jump: jump.map { .init(host: $0.host, port: $0.port, user: $0.username) },
                               directory: thread.workingDirectory, sessionID: session)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let command {
                    Section {
                        Text(command)
                            .font(Theme.monoSmall).textSelection(.enabled)
                            .accessibilityIdentifier("handoff.command")
                        Button {
                            UIPasteboard.general.string = command
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy Command", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .accessibilityIdentifier("handoff.copy")
                        #if targetEnvironment(macCatalyst)
                        Button { openInTerminal(command) } label: { Label("Open in Terminal", systemImage: "terminal") }
                            .accessibilityIdentifier("handoff.terminal")
                        #endif
                        ShareLink(item: command) { Label("Share", systemImage: "square.and.arrow.up") }
                    } footer: {
                        Text("Run it in a terminal on your Mac or PC: it signs in to \(server.displayName) and opens this \(cli.displayName) session where it left off. That computer signs in with its own SSH key or the password — nothing secret is in the command.")
                    }
                    if thread.cliRunActive {
                        Section {
                            Label("The task is still running here. Stop it first, or both will write to the same session.", systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ContentUnavailableView("Nothing to continue yet", systemImage: "terminal",
                                           description: Text("Send the first message; then \(cli.displayName) has a session to continue."))
                }
            }
            .navigationTitle("Continue on a Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Couldn't open Terminal", isPresented: $openFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The command is copied — paste it into Terminal.")
            }
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Writes the command to a .command file and opens it: Terminal runs it in a new window.
    private func openInTerminal(_ command: String) {
        let url = FileManager.default.temporaryDirectory.appending(path: "deckhand-continue.command")
        do {
            try ("#!/bin/sh\n" + command + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch { UIPasteboard.general.string = command; openFailed = true; return }
        UIApplication.shared.open(url) { ok in
            if !ok { UIPasteboard.general.string = command; openFailed = true }
        }
    }
    #endif
}
