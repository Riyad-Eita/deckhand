import SwiftData
import SwiftUI
import UIKit

@main
struct DeckhandApp: App {
    /// Shared so background checks can read the same store.
    static let container: ModelContainer = {
        do { return try ModelContainer(for: Server.self, ChatThread.self, ConnectionRecord.self) }
        catch { fatalError("Couldn't open the app's data: \(error)") }
    }()

    init() {
        TaskNotifier.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                #if DEBUG
                // DECKHAND_APPEARANCE=light|dark: screenshots in both looks from UI tests.
                .preferredColorScheme(ProcessInfo.processInfo.environment["DECKHAND_APPEARANCE"].map { $0 == "dark" ? .dark : .light })
                #endif
                .environment(AppSettings.shared)
                .environment(Connections.shared)
        }
        .modelContainer(Self.container)
        .commands { DeckhandCommands() }
    }
}

/// The Mac menu bar (and keyboard shortcuts on the iPad).
struct DeckhandCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Server") { AppRouter.shared.command = .newServer }.keyboardShortcut("n")
            Button("New Chat") { AppRouter.shared.command = .newChat }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Import Servers…") { AppRouter.shared.command = .importServers }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { AppRouter.shared.command = .settings }.keyboardShortcut(",")
        }
        CommandGroup(after: .textEditing) {
            Button("Search Servers and Tasks") { AppRouter.shared.command = .search }.keyboardShortcut("k")
        }
    }
}

struct RootView: View {
    @AppStorage("onboarding.done") private var onboardingDone = false
    @Query private var servers: [Server]
    @Environment(Connections.self) private var connections
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context

    private var showOnboarding: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DECKHAND_SEED_HOST"] != nil { return false }
        if ProcessInfo.processInfo.environment["DECKHAND_SEED_ONBOARDING"] == "1" { return !onboardingDone }
        #endif
        return !onboardingDone && servers.isEmpty
    }

    var body: some View {
        #if DEBUG
        if let mode = ProcessInfo.processInfo.environment["DECKHAND_WIDGET_PREVIEW"] {
            WidgetPreviewGallery(live: mode == "live")
        } else {
            main
        }
        #else
        main
        #endif
    }

    @Environment(\.horizontalSizeClass) private var horizontalSize

    private var main: some View {
        Group {
            if horizontalSize == .regular {
                // Mac and iPad: servers, chats and tools in a sidebar; what you pick opens next to it.
                NavigationSplitView {
                    ServerListView()
                        .environment(\.inSidebar, true)
                        .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
                } detail: {
                    NavigationStack { SidebarPlaceholder() }
                }
            } else {
                NavigationStack { ServerListView() }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { showOnboarding }, set: { if !$0 { onboardingDone = true } })) {
            OnboardingView { onboardingDone = true }
                .hostKeyPrompt(inSheet: true)
                .serverLinkImport(enabled: true)
                // Mac Catalyst presents the cover in its own window: pass the shared objects explicitly.
                .environment(AppSettings.shared)
                .environment(Connections.shared)
        }
        .hostKeyPrompt()
        .serverLinkImport(enabled: !showOnboarding)
        .onOpenURL { AppRouter.shared.handle($0) }
        .onAppear {
            AppLock.shared.appeared(); CrashReporter.shared.start()
            #if targetEnvironment(macCatalyst)
            // A window that fits a server list and a chat; not smaller than an iPad in portrait.
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.sizeRestrictions?.minimumSize = CGSize(width: 760, height: 620)
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            KeyProtection.shared.lockNow()
        }
        .onChange(of: scenePhase) { _, phase in
            AppLock.shared.scenePhaseChanged(phase)
            if phase == .background { KeyProtection.shared.didEnterBackground() }
            if phase == .active { KeyProtection.shared.didBecomeActive() }
            guard phase == .background else { return }
            let active = ((try? context.fetch(FetchDescriptor<ChatThread>())) ?? []).contains { $0.cliRunActive }
            TaskNotifier.shared.scheduleCheck(hasActiveRuns: active)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await connections.checkConnections()
            await connections.heartbeat()
        }
        #if DEBUG
        .onAppear { DebugSeed.apply(context) }
        .task {
            // DECKHAND_SEED_INTENT=status|run:<command>: run a Siri/Shortcuts intent on the first server and
            // write its answer to tmp/intent-result.txt (checks the intents without Siri).
            if let spec = ProcessInfo.processInfo.environment["DECKHAND_SEED_INTENT"] {
                try? await Task.sleep(for: .seconds(2))
                await DebugSeed.runIntent(spec)
            }
            // DECKHAND_SEED_NTFY=<topic URL>: the ntfy topic (lock-screen approvals, uptime pushes).
            if let t = ProcessInfo.processInfo.environment["DECKHAND_SEED_NTFY"] { AppSettings.shared.ntfyTopicURL = t }
            // DECKHAND_SEED_COMMAND=newServer|newChat|importServers|settings|search: as if chosen in the menu bar.
            if let c = ProcessInfo.processInfo.environment["DECKHAND_SEED_COMMAND"] {
                try? await Task.sleep(for: .seconds(2))
                AppRouter.shared.command = ["newServer": .newServer, "newChat": .newChat, "importServers": .importServers, "settings": .settings, "search": .search][c]
            }
            // DECKHAND_SEED_OPEN_URL=deckhand://thread/<id>: open it like a tapped notification.
            if let s = ProcessInfo.processInfo.environment["DECKHAND_SEED_OPEN_URL"], let url = URL(string: s) {
                try? await Task.sleep(for: .seconds(1))
                AppRouter.shared.handle(url)
            }
            // DECKHAND_SNAPSHOT=<file.png>: the app draws its own windows into a PNG every 2 s (Mac screenshots
            // without screen-recording permission).
            if let path = ProcessInfo.processInfo.environment["DECKHAND_SNAPSHOT"] {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    DebugSeed.snapshot(to: URL(fileURLWithPath: path))
                }
            }
        }
        #endif
    }
}

/// The import screen for a `deckhand://add` link. Attached to the root and to the onboarding cover (a sheet on a
/// covered view can't appear), enabled on whichever is in front.
struct ServerLinkImportModifier: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { enabled ? AppRouter.shared.pendingImport : nil },
                                    set: { AppRouter.shared.pendingImport = $0 })) { link in
            ImportServersView(fromLink: link.candidates)
        }
    }
}

extension View {
    func serverLinkImport(enabled: Bool) -> some View { modifier(ServerLinkImportModifier(enabled: enabled)) }
}

/// Shows the first-connect host key question. Attach it to the root and to every sheet, because an alert
/// on a view that is covered by a sheet cannot appear.
struct HostKeyPromptModifier: ViewModifier {
    @Environment(Connections.self) private var connections
    @Environment(\.isPresented) private var isPresented
    let inSheet: Bool

    func body(content: Content) -> some View {
        content.alert(
            "Trust this server?",
            isPresented: Binding(
                get: { connections.hostKeyPrompt != nil && (inSheet || !connections.sheetOpen) },
                set: { if !$0 { connections.hostKeyPrompt?.respond(false) } }),
            presenting: connections.hostKeyPrompt
        ) { prompt in
            Button("Trust") { prompt.respond(true) }
            Button("Cancel", role: .cancel) { prompt.respond(false) }
        } message: { prompt in
            Text("First connection to \(prompt.serverName). Its host key fingerprint is\n\(prompt.fingerprint)\n\nDeckhand remembers it and warns you if it ever changes.")
        }
        .onAppear { if inSheet { connections.sheetOpen = true } }
        .onDisappear { if inSheet { connections.sheetOpen = false } }
    }
}

extension View {
    func hostKeyPrompt(inSheet: Bool = false) -> some View { modifier(HostKeyPromptModifier(inSheet: inSheet)) }
}

/// Shown next to the sidebar until something is picked.
struct SidebarPlaceholder: View {
    var body: some View {
        ContentUnavailableView("Select a server", systemImage: "server.rack",
                               description: Text("Pick a server, a chat or a tool on the left."))
            .accessibilityIdentifier("sidebar.placeholder")
    }
}

extension EnvironmentValues {
    /// The home list is the sidebar of a split view (Mac, iPad): links open in the detail column.
    @Entry var inSidebar = false
}
