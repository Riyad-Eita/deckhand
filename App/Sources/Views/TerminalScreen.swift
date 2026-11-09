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

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea(edges: .bottom)
            if let session {
                SSHTerminalView(session: session) { closed = true }
                    .id(sessionID)
                    .ignoresSafeArea(.container, edges: .bottom)
            } else if let error {
                ContentUnavailableView {
                    Label("Could not connect", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { reconnect() }
                }
                .foregroundStyle(.white)
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
struct SSHTerminalView: UIViewRepresentable {
    let session: TerminalSession
    var onClosed: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(session: session, onClosed: onClosed) }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        context.coordinator.start(view)
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
        let onClosed: () -> Void
        var reader: Task<Void, Never>?

        init(session: TerminalSession, onClosed: @escaping () -> Void) {
            self.session = session
            self.onClosed = onClosed
        }

        func start(_ view: TerminalView) {
            reader = Task { [session, weak view, onClosed] in
                for await chunk in session.output {
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
