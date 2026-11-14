import Foundation

/// The last CPU, memory and disk values of a server, shared with the home-screen widget through the app group.
/// Only the display name and percentages — no address, user or credentials.
struct ServerSnapshot: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    /// 0…1
    var cpu: Double
    var memory: Double
    /// The fullest disk, 0…1; nil when the server reported no real filesystem (containers).
    var disk: Double?
    var diskMount: String
    var fetched: Date

    enum Level: Int, Comparable, Sendable {
        case ok, warning, critical
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    var diskLevel: Level {
        guard let disk else { return .ok }
        return disk >= 0.95 ? .critical : disk >= 0.85 ? .warning : .ok
    }
    var memoryLevel: Level { memory >= 0.95 ? .critical : memory >= 0.9 ? .warning : .ok }
    /// CPU spikes are normal, so only disk and memory raise the level.
    var level: Level { max(diskLevel, memoryLevel) }

    /// Older than an hour: shown dimmed, the values may not hold anymore.
    func isStale(at now: Date) -> Bool { now.timeIntervalSince(fetched) > 3600 }
}

enum ServerSnapshots {
    static let appGroup = "group.de.fs223.deckhand"
    static let widgetKind = "ServerStatus"

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "server-snapshots.json")
    }

    static func load() -> [ServerSnapshot] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ServerSnapshot].self, from: data)) ?? []
    }

    static func save(_ list: [ServerSnapshot]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Most urgent first, then fullest disk, then by name.
    static func ordered(_ list: [ServerSnapshot]) -> [ServerSnapshot] {
        list.sorted {
            if $0.level != $1.level { return $0.level > $1.level }
            let a = $0.disk ?? 0, b = $1.disk ?? 0
            if abs(a - b) > 0.001 { return a > b }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func link(for id: UUID) -> URL { URL(string: "deckhand://server/\(id.uuidString)")! }
}
