import DeckhandCore
import Foundation
import WidgetKit

/// Keeps the home-screen widget's copy of each server's last CPU, memory and disk values.
@MainActor
enum WidgetSnapshots {
    private static var lastReload = Date.distantPast

    /// After a successful fetch (dashboard, Shortcuts).
    static func record(_ server: Server, _ stats: ServerStats) {
        let fullest = stats.disks.max { $0.usedFraction < $1.usedFraction }
        let snapshot = ServerSnapshot(id: server.id, name: server.displayName, cpu: stats.cpu,
                                      memory: stats.memUsedFraction, disk: fullest?.usedFraction,
                                      diskMount: fullest?.mount ?? "", fetched: .now)
        var list = ServerSnapshots.load()
        let before = list.first { $0.id == server.id }
        list.removeAll { $0.id == server.id }
        list.append(snapshot)
        ServerSnapshots.save(list)
        // The dashboard fetches every few seconds; reload the widget when something it shows changed in kind,
        // otherwise at most every five minutes.
        if before == nil || before?.level != snapshot.level || before?.name != snapshot.name
            || Date.now.timeIntervalSince(lastReload) > 300 {
            reload()
        }
    }

    /// Drop servers that are gone and follow renames (at launch and after a delete).
    static func sync(_ servers: [Server]) {
        let names = Dictionary(servers.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let list = ServerSnapshots.load()
        let kept = list.compactMap { s -> ServerSnapshot? in
            guard let name = names[s.id] else { return nil }
            var s = s
            s.name = name
            return s
        }
        guard kept != list else { return }
        ServerSnapshots.save(kept)
        reload()
    }

    private static func reload() {
        lastReload = .now
        WidgetCenter.shared.reloadTimelines(ofKind: ServerSnapshots.widgetKind)
    }
}
