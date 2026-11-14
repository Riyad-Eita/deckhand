import DeckhandCore
import DeckhandSSH
import SwiftTerm
import SwiftUI

struct TerminalScreen: View {
    let server: Server
    @Binding var pendingCommand: String?
    @Environment(Connections.self) private var connections
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: TerminalSession?
    @State private var sessionID = UUID()
    @State private var error: String?
    @State private var closed = false
    @State private var attempt = 0
    @State private var explaining: String?
    @State private var investigatePrompt: String?
    @State private var terminalView: TerminalView?
    @State private var recent = RecentOutput()
    @State private var showingSnippets = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea(edges: .bottom)
            if let session {
                SSHTerminalView(session: session, recent: recent, onView: { terminalView = $0 }) { closed = true }
                    .id(sessionID)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            // The selection if there is one, else what's on screen lately.
                            let picked = terminalView?.getSelection() ?? ""
                            explaining = picked.isEmpty ? Explain.tail(Explain.stripANSI(recent.text), lines: 40) : picked
                        } label: {
                            Image(systemName: "sparkle.magnifyingglass").font(.system(size: 15, weight: .semibold))
                                .padding(9).background(.ultraThinMaterial, in: Circle())
                        }
                        .padding(10)
                        .accessibilityLabel("Explain")
                        .accessibilityIdentifier("terminal.explain")
                    }
                    .overlay(alignment: .topTrailing) {
                        Button { showingSnippets = true } label: {
                            Image(systemName: "text.badge.star").font(.system(size: 15, weight: .semibold))
                                .padding(9).background(.ultraThinMaterial, in: Circle())
                        }
                        .padding(.top, 10).padding(.trailing, 60)
                        .accessibilityLabel("Snippets")
                        .accessibilityIdentifier("terminal.snippets")
                    }
            } else if let error {
                VStack(spacing: 16) {
                    ProblemView(message: error).foregroundStyle(.white)
                    Button("Try Again") { reconnect() }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white).frame(maxHeight: .infinity)
            }
            if closed {
                HStack {
                    Label("Disconnected", systemImage: "wifi.slash").font(.subheadline)
                    Spacer()
                    Button("Reconnect") { reconnect() }.buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding()
            }
        }
        .task(id: attempt) { await open() }
        .onChange(of: pendingCommand) { sendPending() }
        .onChange(of: session == nil) { sendPending() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && closed { reconnect() }
        }
        .onDisappear { session?.close() }
        .sheet(item: Binding(get: { explaining.map { ExplainText(text: $0) } }, set: { explaining = $0?.text })) { e in
            ExplainSheet(text: e.text, context: String(localized: "the terminal")) { investigatePrompt = $0 }
        }
        .investigate(on: server, prompt: $investigatePrompt)
        .sheet(isPresented: $showingSnippets) {
            SnippetsSheet(server: server) { text, run in session?.send(run ? text + "\n" : text) }
        }
    }

    private func reconnect() {
        session?.close()
        session = nil
        error = nil
        closed = false
        attempt += 1
    }

    private func sendPending() {
        guard let session, let command = pendingCommand else { return }
        pendingCommand = nil
        session.send(command + "\n")
    }

    private func open() async {
        do {
            let connection = try await connections.connection(for: server)
            let new = try await connection.openTerminal(cols: 80, rows: 24)
            // Logins and other queued commands run in a plain shell; otherwise attach to the kept session.
            if settings.keepTerminalSessions && pendingCommand == nil {
                new.send("clear; " + PersistentSession.attachCommand + "\n")
            }
            sessionID = UUID()
            session = new
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// SwiftTerm's UIKit terminal wired to an SSH PTY session.
/// The last output of a terminal as text, for "Explain" (SwiftTerm doesn't expose its screen buffer).
final class RecentOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > 32_000 { data.removeFirst(data.count - 24_000) }
        }
    }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

struct SSHTerminalView: UIViewRepresentable {
    let session: TerminalSession
    var recent: RecentOutput? = nil
    var onView: (TerminalView) -> Void = { _ in }
    var onClosed: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(session: session, recent: recent, onClosed: onClosed) }

    func makeUIView(context: Context) -> TerminalView {
        let view = DeckhandTerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        context.coordinator.start(view)
        DispatchQueue.main.async { onView(view) }
        #if DEBUG
        let focus = ProcessInfo.processInfo.environment["DECKHAND_SEED_NOKEYBOARD"] == nil
        #else
        let focus = true
        #endif
        if focus { DispatchQueue.main.async { _ = view.becomeFirstResponder() } }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.reader?.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession
        let recent: RecentOutput?
        let onClosed: () -> Void
        var reader: Task<Void, Never>?

        init(session: TerminalSession, recent: RecentOutput?, onClosed: @escaping () -> Void) {
            self.session = session
            self.recent = recent
            self.onClosed = onClosed
        }

        func start(_ view: TerminalView) {
            reader = Task { [session, weak view, onClosed, recent] in
                for await chunk in session.output {
                    recent?.append(Data(chunk))
                    view?.feed(byteArray: ArraySlice([UInt8](chunk)))
                }
                if !Task.isCancelled {
                    view?.feed(text: "\r\n[connection closed]\r\n")
                    onClosed()
                }
            }
        }

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.send(Data(data))
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session.resize(cols: newCols, rows: newRows)
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
            guard let url = URL(string: request.link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            Task { @MainActor in UIApplication.shared.open(url) }
        }
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                Task { @MainActor in UIPasteboard.general.string = text }
            }
        }
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// SwiftTerm's view without answers to xterm size reports (CSI 14/16/18/19 t and friends).
/// Over SSH these replies can arrive after tmux or the shell stopped waiting for them and then show up as
/// typed text like ";52;55t". Size changes still reach the server through the SSH window-change request.
final class DeckhandTerminalView: TerminalView {
    nonisolated override func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        switch command {
        case .reportTextAreaPixelDimension, .reportTerminalWindowPixelDimension, .reportSizeOfScreenInPixels,
             .reportCellSizeInPixels, .reportTextAreaCharacters, .reportScreenSizeCharacters,
             .reportTerminalPosition, .reportTextAreaPosition:
            return []
        default:
            return super.windowCommand(source: source, command: command)
        }
    }
}
