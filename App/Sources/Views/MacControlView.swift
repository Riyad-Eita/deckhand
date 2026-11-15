import DeckhandCore
import SwiftUI

/// Small things on a Mac added as a server, from the iPhone: its screen, a Shortcut, an app or link, the clipboard,
/// staying awake. Everything runs over SSH as the signed-in user (see `MacControl`).
struct MacControlView: View {
    let server: Server
    private var connections: Connections { .shared }

    @State private var screenshot: UIImage?
    @State private var shooting = false
    @State private var shortcuts: [String]?
    @State private var target = ""
    @State private var clip = ""
    @State private var awake: Bool?
    @State private var status: String?
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                if let screenshot {
                    Image(uiImage: screenshot).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("mac.screenshot")
                }
                Button { Task { await takeScreenshot() } } label: {
                    HStack { Label(screenshot == nil ? "Look at the screen" : "Take another", systemImage: "camera.viewfinder"); Spacer(); if shooting { ProgressView() } }
                }
                .disabled(shooting)
                .accessibilityIdentifier("mac.shoot")
            } header: { Text("Screen") }

            Section {
                if let shortcuts {
                    if shortcuts.isEmpty { Text("No Shortcuts on this Mac.").foregroundStyle(.secondary) }
                    ForEach(shortcuts, id: \.self) { name in
                        Button { Task { await perform(MacControl.runShortcut(name), done: String(localized: "Ran \u{201C}\(name)\u{201D}.")) } } label: {
                            Label(name, systemImage: "square.2.layers.3d")
                        }
                    }
                } else {
                    HStack { ProgressView(); Text("Loading Shortcuts…").foregroundStyle(.secondary) }
                }
            } header: { Text("Shortcuts") }

            Section {
                TextField("App name or link", text: $target)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("mac.target")
                Button("Open on the Mac") {
                    guard let cmd = MacControl.open(target) else { return }
                    Task { await perform(cmd, done: String(localized: "Opened on the Mac.")) }
                }
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: { Text("Open") }

            Section {
                TextField("Text", text: $clip, axis: .vertical).lineLimit(1...5)
                    .accessibilityIdentifier("mac.clip")
                Button("Copy to the Mac's clipboard") { Task { await sendClipboard() } }
                    .disabled(clip.isEmpty)
            } header: { Text("Clipboard") } footer: {
                Text("Paste it on the Mac with ⌘V.")
            }

            Section {
                if awake == true {
                    Label("Deckhand keeps this Mac awake.", systemImage: "cup.and.saucer.fill").foregroundStyle(.green)
                    Button("Let it sleep again") { Task { await perform(MacControl.stopKeepAwakeCommand, done: String(localized: "The Mac may sleep again.")); await refreshAwake() } }
                } else {
                    Button("Keep awake for 1 hour") { Task { await perform(MacControl.keepAwake(hours: 1), done: String(localized: "Stays awake for an hour.")); await refreshAwake() } }
                    Button("Keep awake for 8 hours") { Task { await perform(MacControl.keepAwake(hours: 8), done: String(localized: "Stays awake for 8 hours.")); await refreshAwake() } }
                }
            } header: { Text("Stay awake") } footer: {
                Text("While a long task runs, the Mac doesn't go to sleep. The display can still turn off.")
            }

            if let status { Section { Label(status, systemImage: "checkmark.circle").foregroundStyle(.green) } }
            if let problem { Section { ProblemView(message: problem, compact: true) } }
        }
        .navigationTitle("Control This Mac")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshAwake()
            shortcuts = MacControl.shortcuts((try? await run(MacControl.listShortcutsCommand)) ?? "")
        }
    }

    private func run(_ command: String) async throws -> String {
        let conn = try await connections.connection(for: server)
        return try await conn.run(command, timeout: .seconds(30)).stdout
    }

    private func perform(_ command: String, done: String) async {
        status = nil; problem = nil
        do {
            switch MacControl.outcome(try await run(command)) {
            case .ok: status = done
            case .failed(let what): problem = message(for: what)
            }
        } catch { problem = error.localizedDescription }
    }

    private func message(for what: String) -> String {
        switch what {
        case "screen": String(localized: "The Mac didn't allow a screenshot over SSH. On the Mac: System Settings → Privacy & Security → Screen & System Audio Recording → add “sshd-keygen-wrapper” (/usr/libexec), then try again.")
        case "shortcut": String(localized: "The Shortcut didn't finish. Shortcuts that ask a question or show something need someone at the Mac.")
        case "app": String(localized: "No app with that name on the Mac.")
        case "clipboard": String(localized: "The clipboard can only be set while you're signed in on the Mac.")
        default: String(localized: "That didn't work on the Mac.")
        }
    }

    private func takeScreenshot() async {
        shooting = true; status = nil; problem = nil
        defer { shooting = false }
        do {
            let conn = try await connections.connection(for: server)
            let r = try await conn.run(MacControl.screenshotCommand, timeout: .seconds(30))
            guard MacControl.outcome(r.stdout) == .ok else { problem = message(for: "screen"); return }
            let data = try await conn.download(MacControl.shotPath, maxBytes: 20_000_000)
            _ = try? await conn.run("rm -f \(MacControl.shotPath)", timeout: .seconds(10))
            screenshot = UIImage(data: data)
        } catch { problem = error.localizedDescription }
    }

    /// The text goes up as a file (never on a command line), into pbcopy, and the file is removed.
    private func sendClipboard() async {
        status = nil; problem = nil
        do {
            let conn = try await connections.connection(for: server)
            let path = try await conn.upload(Data(clip.utf8), named: "deckhand-clip.txt", into: "/tmp") { _ in }
            let q = ShellQuote.quote(path)
            let r = try await conn.run("\(MacControl.clipboardCommand) < \(q); rm -f \(q)", timeout: .seconds(15))
            switch MacControl.outcome(r.stdout) {
            case .ok: status = String(localized: "On the Mac's clipboard.")
            case .failed(let what): problem = message(for: what)
            }
        } catch { problem = error.localizedDescription }
    }

    private func refreshAwake() async {
        awake = (try? await run(MacControl.awakeStatusCommand))?.contains("@@awake")
    }
}
