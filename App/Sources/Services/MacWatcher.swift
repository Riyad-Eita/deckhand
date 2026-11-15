#if targetEnvironment(macCatalyst)
import DeckhandCore
import Foundation
import SwiftData

/// On the Mac the app keeps running while its windows are in the background, but iOS-style background refresh
/// never comes. While Deckhand runs, this checks tasks still running on servers (and App Store reviews) so the
/// notifications arrive, and keeps the status widget's numbers fresh.
@MainActor
final class MacWatcher {
    static let shared = MacWatcher()
    private var loop: Task<Void, Never>?
    private var lastStats = Date.distantPast
    private var lastReviews = Date.distantPast

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))   // let the app settle first
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func tick() async {
        // Never trigger a Touch ID prompt from the background: skip while the keys are locked.
        if KeyProtection.shared.enabled && !KeyProtection.shared.isUnlocked { return }
        let context = ModelContext(DeckhandApp.container)
        let threads = (try? context.fetch(FetchDescriptor<ChatThread>())) ?? []
        let running = threads.contains { $0.cliRunActive && $0.cliRunID != nil }
        // Running tasks every minute; otherwise App Store reviews every 15 minutes.
        if running || Date.now.timeIntervalSince(lastReviews) > 15 * 60 {
            lastReviews = .now
            _ = await TaskNotifier.shared.checkServers()
        }
        if Date.now.timeIntervalSince(lastStats) > 5 * 60 {
            lastStats = .now
            await refreshWidget(context)
        }
    }

    /// The widget shows the last CPU, memory and disk values: fetch them for the first servers in the list.
    private func refreshWidget(_ context: ModelContext) async {
        let servers = ((try? context.fetch(FetchDescriptor<Server>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []).prefix(6)
        for server in servers {
            guard let conn = try? await Connections.shared.connection(for: server),
                  let r = try? await conn.run(ServerStats.probeCommand, timeout: .seconds(20)),
                  let stats = ServerStats.parse(r.stdout) else { continue }
            WidgetSnapshots.record(server, stats)
        }
    }
}
#endif
