import Foundation

/// The server list across the user's devices (iCloud key-value store). Only what's needed to reach a server
/// travels — never a password, key or passphrase; a server that arrives on another device asks to sign in there.
/// Every server is one record with the time of its last change; a deletion stays as a marker for a while so other
/// devices learn about it. Conflicts are settled per server: the newer change wins.
public enum ServerSync {
    public struct Record: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var host: String
        public var port: Int
        public var user: String
        public var group: String
        public var jumpHostID: UUID?
        public var authKind: String
        public var pinnedHostKey: String?
        public var isMac: Bool
        public var updatedAt: Date
        public var deleted: Bool

        public init(id: UUID, name: String, host: String, port: Int, user: String, group: String = "", jumpHostID: UUID? = nil,
                    authKind: String, pinnedHostKey: String? = nil, isMac: Bool = false, updatedAt: Date, deleted: Bool = false) {
            self.id = id; self.name = name; self.host = host; self.port = port; self.user = user; self.group = group
            self.jumpHostID = jumpHostID; self.authKind = authKind; self.pinnedHostKey = pinnedHostKey; self.isMac = isMac
            self.updatedAt = updatedAt; self.deleted = deleted
        }

        /// What the user would notice changing (not the timestamp).
        public var fingerprint: String {
            [name, host, String(port), user, group, jumpHostID?.uuidString ?? "", authKind, pinnedHostKey ?? "", isMac ? "mac" : "",
             deleted ? "deleted" : ""].joined(separator: "\u{1F}")
        }

        public func tombstone(at date: Date) -> Record {
            var r = self; r.deleted = true; r.updatedAt = date; r.pinnedHostKey = nil; return r
        }
    }

    /// Deletion markers older than this are dropped (every device has long since seen them).
    public static let tombstoneLifetime: TimeInterval = 60 * 24 * 3600

    /// Settles local and cloud records: per id the newer change wins (on a tie the cloud's, so all devices agree).
    public static func merge(local: [Record], remote: [Record], now: Date = Date()) -> [Record] {
        var byID: [UUID: Record] = [:]
        for r in remote { byID[r.id] = newer(byID[r.id], r, preferSecond: true) }
        for l in local { byID[l.id] = newer(byID[l.id], l, preferSecond: false) }
        return byID.values
            .filter { !$0.deleted || now.timeIntervalSince($0.updatedAt) < tombstoneLifetime }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private static func newer(_ a: Record?, _ b: Record, preferSecond: Bool) -> Record {
        guard let a else { return b }
        if a.updatedAt == b.updatedAt { return preferSecond ? b : a }
        return a.updatedAt > b.updatedAt ? a : b
    }

    /// The device's records for this round: servers whose content changed since the last sync get `now` as their
    /// change time; servers that were synced before but are gone locally become deletion markers.
    /// - Parameters:
    ///   - current: the servers on this device, with their last known change time.
    ///   - lastSynced: fingerprint and time per id after the previous sync.
    public static func localRecords(current: [Record], lastSynced: [UUID: (fingerprint: String, at: Date)], now: Date = Date())
        -> [Record] {
        var out: [Record] = current.map { r in
            var r = r
            if let last = lastSynced[r.id] { r.updatedAt = last.fingerprint == r.fingerprint ? last.at : now } else { r.updatedAt = now }
            return r
        }
        let present = Set(current.map(\.id))
        for (id, last) in lastSynced where !present.contains(id) && !last.fingerprint.hasSuffix("deleted") {
            out.append(Record(id: id, name: "", host: "", port: 22, user: "", authKind: "key", updatedAt: now, deleted: true))
        }
        return out
    }

    public static func encode(_ records: [Record]) -> Data? {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = .sortedKeys
        return try? e.encode(records)
    }

    public static func decode(_ data: Data?) -> [Record] {
        guard let data else { return [] }
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode([Record].self, from: data)) ?? []
    }
}
