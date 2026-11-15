import DeckhandCore
import DeckhandSSH
import SwiftTerm
import SwiftUI

/// The terminal with tabs: each tab is its own shell (and kept session) on the server. Tabs stay connected in the
/// background, so switching is instant; which tabs are open is remembered per server.
struct TerminalScreen: View {
    let server: Server
    @Binding var pendingCommand: String?
    @Environment(Connections.self) private var connections
    @Environment(AppSettings.self) private var settings
    @State private var tabs: [Int] = [1]
    @State private var selected = 1
    @State private var titles: [Int: String] = [:]
    @State private var loaded = false

    private var tabsKey: String { "terminal.tabs.\(server.id.uuidString)" }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            ZStack {
                ForEach(tabs, id: \.self) { tab in
                    TerminalPane(server: server, tab: tab, isActive: tab == selected,
                                 pendingCommand: tab == selected ? $pendingCommand : .constant(nil),
                                 onTitle: { titles[tab] = $0 }, onShortcut: handle)
                        .opacity(tab == selected ? 1 : 0)
                        .allowsHitTesting(tab == selected)
                        .accessibilityHidden(tab != selected)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let saved = (UserDefaults.standard.array(forKey: tabsKey) as? [Int])?.filter { $0 >= 1 } ?? []
            if !saved.isEmpty { tabs = saved; selected = saved[0] }
        }
        .onChange(of: tabs) { UserDefaults.standard.set(tabs, forKey: tabsKey) }
        #if targetEnvironment(macCatalyst)
        // The window's toolbar sits on the terminal's color, so its buttons follow the theme.
        .toolbarBackground(SSHTerminalView.swiftUIColor(TerminalTheme.named(settings.terminalTheme).background), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(TerminalTheme.named(settings.terminalTheme).isLight ? .light : .dark, for: .navigationBar)
        #endif
    }

    private var tabBar: some View {
        let theme = TerminalTheme.named(settings.terminalTheme)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(tabs.enumerated()), id: \.element) { i, tab in
                    let title = TerminalTabs.title(titles[tab], tab: tab)
                    HStack(spacing: 4) {
                        Text(title).font(.caption.weight(tab == selected ? .semibold : .regular)).lineLimit(1)
                        if tabs.count > 1 && tab == selected {
                            Button { close(tab) } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                                .accessibilityLabel(String(localized: "Close \(title)"))
                                .accessibilityIdentifier("terminal.tab.close")
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(tab == selected ? Color.primary.opacity(0.12) : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { selected = tab }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(tab == selected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("terminal.tab.\(i + 1)")
                }
                Button { add() } label: { Image(systemName: "plus").font(.footnote.weight(.semibold)).frame(width: 30, height: 28) }
                    .accessibilityLabel("New tab")
                    .accessibilityIdentifier("terminal.tab.new")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .foregroundStyle(theme.isLight ? Color.black : Color.white)
        .background(SSHTerminalView.swiftUIColor(theme.background))
        .environment(\.colorScheme, theme.isLight ? .light : .dark)
    }

    private func handle(_ shortcut: TerminalShortcut) {
        guard let i = tabs.firstIndex(of: selected) else { return }
        switch shortcut {
        case .newTab: add()
        case .closeTab: close(selected)
        case .nextTab: selected = tabs[(i + 1) % tabs.count]
        case .previousTab: selected = tabs[(i - 1 + tabs.count) % tabs.count]
        case .tab(let n): if n <= tabs.count { selected = tabs[n - 1] }
        case .larger: settings.terminalFontSize = TerminalFont.clamp(settings.terminalFontSize + 1)
        case .smaller: settings.terminalFontSize = TerminalFont.clamp(settings.terminalFontSize - 1)
        case .defaultSize: settings.terminalFontSize = TerminalFont.default
        case .clear: break   // handled by the pane
        }
    }

    func add() {
        let n = TerminalTabs.next(after: tabs)
        tabs.append(n)
        selected = n
    }

    private func close(_ tab: Int) {
        guard tabs.count > 1, let i = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: i)
        titles[tab] = nil
        if selected == tab { selected = tabs[max(0, i - 1)] }
        // The tab is gone, so is its kept session on the server.
        if settings.keepTerminalSessions {
            let server = server
            Task { _ = try? await connections.connection(for: server).run(PersistentSession.endCommand(tab: tab), timeout: .seconds(10)) }
        }
    }
}

/// One shell on the server.
struct TerminalPane: View {
    let server: Server
    let tab: Int
    let isActive: Bool
    @Binding var pendingCommand: String?
    var onTitle: (String?) -> Void = { _ in }
    var onShortcut: (TerminalShortcut) -> Void = { _ in }
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
            SSHTerminalView.swiftUIColor(TerminalTheme.named(settings.terminalTheme).background).ignoresSafeArea(edges: .bottom)
            if let session {
                SSHTerminalView(session: session, recent: recent, focus: isActive, onView: { terminalView = $0 }, onTitle: onTitle,
                                onShortcut: { action in
                                    if action == .clear {
                                        terminalView?.feed(text: TerminalShortcut.clearLocal)
                                        session.send(TerminalShortcut.clearRemote)
                                    } else {
                                        onShortcut(action)
                                    }
                                }) { closed = true }
                    .id(sessionID)
                    .ignoresSafeArea(.container, edges: .bottom)
                    #if !targetEnvironment(macCatalyst)
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 14) {
                            appearanceMenu
                            snippetsButton
                            explainButton
                        }
                        .labelStyle(.iconOnly)
                        .menuStyle(.button)
                        .buttonStyle(FloatingCircle())
                        .padding(10)
                    }
                    #endif
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
        #if targetEnvironment(macCatalyst)
        .toolbar {
            // On the Mac these sit in the window's toolbar instead of over the text.
            if isActive && session != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    appearanceMenu
                    snippetsButton
                    explainButton
                }
            }
        }
        #endif
        .task(id: attempt) { await open() }
        .onChange(of: pendingCommand) { sendPending() }
        .onChange(of: session == nil) { sendPending() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && closed { reconnect() }
        }
        .onChange(of: isActive) { _, active in if active { _ = terminalView?.becomeFirstResponder() } }
        .onDisappear { session?.close() }
        .sheet(item: Binding(get: { explaining.map { ExplainText(text: $0) } }, set: { explaining = $0?.text })) { e in
            ExplainSheet(text: e.text, context: String(localized: "the terminal")) { investigatePrompt = $0 }
        }
        .investigate(on: server, prompt: $investigatePrompt)
        .sheet(isPresented: $showingSnippets) {
            SnippetsSheet(server: server) { text, run in session?.send(run ? text + "\n" : text) }
        }
    }

    private var explainButton: some View {
        Button {
            // The selection if there is one, else what's on screen lately.
            let picked = terminalView?.getSelection() ?? ""
            explaining = picked.isEmpty ? Explain.tail(Explain.stripANSI(recent.text), lines: 40) : picked
        } label: {
            Label("Explain", systemImage: "sparkle.magnifyingglass")
        }
        .accessibilityIdentifier("terminal.explain")
    }

    private var snippetsButton: some View {
        Button { showingSnippets = true } label: { Label("Snippets", systemImage: "text.badge.star") }
            .accessibilityIdentifier("terminal.snippets")
    }

    private var appearanceMenu: some View {
        Menu {
            Picker("Colors", selection: Bindable(settings).terminalTheme) {
                ForEach(TerminalTheme.all) { t in Text(t.name).tag(t.id) }
            }
            Section(String(localized: "Text size \(Int(settings.terminalFontSize))")) {
                Button { settings.terminalFontSize = TerminalFont.clamp(settings.terminalFontSize + 1) } label: { Label("Larger", systemImage: "textformat.size.larger") }
                Button { settings.terminalFontSize = TerminalFont.clamp(settings.terminalFontSize - 1) } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
                Button { settings.terminalFontSize = TerminalFont.default } label: { Label("Default size", systemImage: "arrow.counterclockwise") }
            }
        } label: {
            Label("Text size and colors", systemImage: "textformat.size")
        }
        .accessibilityIdentifier("terminal.appearance")
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
                new.send("clear; " + PersistentSession.attachCommand(tab: tab) + "\n")
            }
            sessionID = UUID()
            session = new
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The round, frosted buttons floating over the terminal on iPhone and iPad.
private struct FloatingCircle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .padding(9)
            .background(.ultraThinMaterial, in: Circle())
            .opacity(configuration.isPressed ? 0.6 : 1)
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
    var focus = true
    var onView: (TerminalView) -> Void = { _ in }
    var onTitle: (String?) -> Void = { _ in }
    var onShortcut: (TerminalShortcut) -> Void = { _ in }
    var onClosed: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(session: session, recent: recent, onTitle: onTitle, onClosed: onClosed) }

    func makeUIView(context: Context) -> TerminalView {
        let view = DeckhandTerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.accessibilityIdentifier = "terminal.view"
        view.onShortcut = onShortcut
        Self.style(view, theme: TerminalTheme.named(AppSettings.shared.terminalTheme), size: AppSettings.shared.terminalFontSize)
        context.coordinator.applied = (AppSettings.shared.terminalTheme, AppSettings.shared.terminalFontSize)
        // Pinch to zoom: changes the font size; the terminal reflows and tells the server its new size.
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:)))
        view.addGestureRecognizer(pinch)
        #if targetEnvironment(macCatalyst)
        view.setUpForMac()
        #endif
        context.coordinator.view = view
        context.coordinator.start(view)
        DispatchQueue.main.async { onView(view) }
        #if DEBUG
        let focus = focus && ProcessInfo.processInfo.environment["DECKHAND_SEED_NOKEYBOARD"] == nil
        #else
        let focus = focus
        #endif
        if focus { DispatchQueue.main.async { _ = view.becomeFirstResponder() } }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        let wanted = (AppSettings.shared.terminalTheme, AppSettings.shared.terminalFontSize)
        guard context.coordinator.applied.0 != wanted.0 || context.coordinator.applied.1 != wanted.1 else { return }
        Self.style(uiView, theme: TerminalTheme.named(wanted.0), size: wanted.1)
        context.coordinator.applied = wanted
    }

    static func swiftUIColor(_ hex: String) -> SwiftUI.Color { SwiftUI.Color(uiColor: uiColor(hex)) }

    static func uiColor(_ hex: String) -> UIColor {
        let c = TerminalTheme.rgb(hex) ?? (0, 0, 0)
        return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    static func style(_ view: TerminalView, theme: TerminalTheme, size: Double) {
        view.font = UIFont.monospacedSystemFont(ofSize: TerminalFont.clamp(size), weight: .regular)
        view.nativeBackgroundColor = uiColor(theme.background)
        view.nativeForegroundColor = uiColor(theme.foreground)
        view.caretColor = uiColor(theme.cursor)
        view.installColors(theme.ansi.map { hex in
            let c = TerminalTheme.rgb(hex) ?? (0, 0, 0)
            return SwiftTerm.Color(red: UInt16(c.r * 65535), green: UInt16(c.g * 65535), blue: UInt16(c.b * 65535))
        })
        view.keyboardAppearance = theme.isLight ? .light : .dark
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.reader?.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession
        let recent: RecentOutput?
        let onClosed: () -> Void
        var reader: Task<Void, Never>?
        weak var view: TerminalView?
        var applied: (String, Double) = ("", 0)
        private var pinchStart: Double = TerminalFont.default

        @objc func pinched(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began: pinchStart = AppSettings.shared.terminalFontSize
            case .changed:
                let size = TerminalFont.clamp(pinchStart * Double(g.scale))
                if let view, size != applied.1 {
                    view.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
                    applied.1 = size
                }
            case .ended, .cancelled:
                AppSettings.shared.terminalFontSize = applied.1   // remembered for next time
            default: break
            }
        }

        let onTitle: (String?) -> Void

        init(session: TerminalSession, recent: RecentOutput?, onTitle: @escaping (String?) -> Void, onClosed: @escaping () -> Void) {
            self.session = session
            self.recent = recent
            self.onTitle = onTitle
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

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {
            Task { @MainActor in self.onTitle(title) }
        }
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
    /// Cmd shortcuts from a hardware keyboard (tabs, clear, text size).
    var onShortcut: ((TerminalShortcut) -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        TerminalShortcut.all.map { s in
            let c = UIKeyCommand(title: s.title, action: #selector(shortcut(_:)), input: s.input,
                                 modifierFlags: s.shift ? [.command, .shift] : .command)
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
    }

    @objc private func shortcut(_ command: UIKeyCommand) {
        guard let input = command.input,
              let action = TerminalShortcut.action(input: input, shift: command.modifierFlags.contains(.shift)) else { return }
        onShortcut?(action)
    }

    #if targetEnvironment(macCatalyst)
    /// On the Mac: no on-screen key bar (there is a real keyboard), and click-and-drag selects text like Terminal.
    /// While a program asks for the mouse (tmux with mouse on, vim), dragging goes to it; hold Option to select anyway.
    func setUpForMac() {
        inputAccessoryView = nil
        let drag = UIPanGestureRecognizer(target: self, action: #selector(mouseSelect(_:)))
        drag.maximumNumberOfTouches = 1
        drag.allowedScrollTypesMask = []   // scroll wheel and trackpad keep scrolling
        addGestureRecognizer(drag)
        panGestureRecognizer.require(toFail: drag)
        mouseDrag = drag
        #if DEBUG
        // DECKHAND_SEED_DRAG=x1,y1,x2,y2: select as a mouse drag between two points would, then write the text out.
        let p = (ProcessInfo.processInfo.environment["DECKHAND_SEED_DRAG"] ?? "").split(separator: ",").compactMap { Double($0) }
        if p.count == 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self else { return }
                self.setSelectionRange(start: self.cell(at: CGPoint(x: p[0], y: p[1] + self.contentOffset.y)),
                                       end: self.cell(at: CGPoint(x: p[2], y: p[3] + self.contentOffset.y)))
                try? (self.getSelection() ?? "").write(to: FileManager.default.temporaryDirectory.appending(path: "drag.txt"),
                                                        atomically: true, encoding: .utf8)
            }
        }
        #endif
    }

    private weak var mouseDrag: UIPanGestureRecognizer?
    private var dragAnchor: Position?

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === mouseDrag else { return super.gestureRecognizerShouldBegin(g) }
        let programWantsMouse = allowMouseReporting && programMouse
        return !programWantsMouse || g.modifierFlags.contains(.alternate)
    }

    /// Whether the program in the terminal asked for mouse events.
    private var programMouse = false

    nonisolated override func mouseModeChanged(source: Terminal) {
        super.mouseModeChanged(source: source)
        let on = source.mouseMode != .off
        DispatchQueue.main.async { [weak self] in self?.programMouse = on }
    }

    @objc private func mouseSelect(_ g: UIPanGestureRecognizer) {
        let here = cell(at: g.location(in: self))
        switch g.state {
        case .began:
            _ = becomeFirstResponder()
            dragAnchor = here
            clearSelection()
        case .changed:
            guard let dragAnchor else { return }
            setSelectionRange(start: dragAnchor, end: here)
        default:
            dragAnchor = nil
        }
    }

    /// The buffer cell under a point, measured the way SwiftTerm lays out its grid.
    private func cell(at point: CGPoint) -> Position {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        let width = ("W" as NSString).size(withAttributes: [.font: font]).width
        let cellWidth = max(1, (width * scale).rounded() / scale)
        let cellHeight = max(1, ceil(ceil(font.ascender - font.descender + font.leading) * scale) / scale)
        let col = min(max(0, Int((point.x / cellWidth).rounded())), Int(bounds.width / cellWidth))
        let row = max(0, Int(point.y / cellHeight))
        return Position(col: col, row: row)
    }
    #endif

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
