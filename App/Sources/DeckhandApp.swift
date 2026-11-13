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

    init() { TaskNotifier.shared.start() }

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
        @Bindable var connections = connections
        NavigationStack {
            ServerListView()
        }
        .fullScreenCover(isPresented: Binding(get: { showOnboarding }, set: { if !$0 { onboardingDone = true } })) {
            OnboardingView { onboardingDone = true }
                .hostKeyPrompt(inSheet: true)
        }
        .hostKeyPrompt()
        .onOpenURL { AppRouter.shared.handle($0) }
        .onAppear { AppLock.shared.appeared(); CrashReporter.shared.start() }
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
            // DECKHAND_SEED_OPEN_URL=deckhand://thread/<id>: open it like a tapped notification.
            if let s = ProcessInfo.processInfo.environment["DECKHAND_SEED_OPEN_URL"], let url = URL(string: s) {
                try? await Task.sleep(for: .seconds(1))
                AppRouter.shared.handle(url)
            }
        }
        #endif
    }
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
