import DeckhandCore
import Foundation
import SwiftData

/// Keeps the server list in iCloud's key-value store (see `ServerSync`): no passwords, keys or passphrases.
/// Runs when the app becomes active, when another device changed the list, and every 30 seconds while the app runs.
@MainActor
final class ServerSyncService {
    static let shared = ServerSyncService()
    private let store = NSUbiquitousKeyValueStore.default
    private let cloudKey = "servers.v1"
    private let lastKey = "sync.servers.last"
    private var loop: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main) { _ in
            Task { @MainActor in ServerSyncService.shared.syncNow() }
        }
        settingChanged()
    }

    func settingChanged() {
        loop?.cancel(); loop = nil
        #if DEBUG
        // DECKHAND_SYNC_CLEAR=1: empty this app's iCloud server list (after sync tests).
        if ProcessInfo.processInfo.environment["DECKHAND_SYNC_CLEAR"] == "1" {
            store.removeObject(forKey: cloudKey); store.synchronize()
            UserDefaults.standard.removeObject(forKey: lastKey)
        }
        #endif
        guard AppSettings.shared.syncServers else { return }
        store.synchronize()
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))   // after launch work (and debug seeding) is done
            while !Task.isCancelled {
                self?.syncNow()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// One round: this device's changes and the cloud's are merged and written to both sides.
    func syncNow() {
        guard AppSettings.shared.syncServers else { return }
        let context = ModelContext(DeckhandApp.container)
        let servers = (try? context.fetch(FetchDescriptor<Server>())) ?? []
        let last = loadLast()
        let local = ServerSync.localRecords(current: servers.map(Self.record), lastSynced: last)
        let remote = ServerSync.decode(store.data(forKey: cloudKey))
        let merged = ServerSync.merge(local: local, remote: remote)

        var changed = false
        let byID = Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for r in merged {
            if r.deleted {
                if let s = byID[r.id] { context.delete(s); changed = true }
            } else if let s = byID[r.id] {
                if Self.record(s).fingerprint != r.fingerprint { Self.apply(r, to: s); changed = true }
            } else {
                let s = Server(name: r.name, host: r.host, port: r.port, username: r.user, authKind: AuthKind(rawValue: r.authKind) ?? .key)
                s.id = r.id
                Self.apply(r, to: s)
                context.insert(s); changed = true
            }
        }
        if changed { try? context.save() }
        if merged != remote, let data = ServerSync.encode(merged) { store.set(data, forKey: cloudKey) }
        saveLast(Dictionary(merged.map { ($0.id, ($0.fingerprint, $0.updatedAt)) }, uniquingKeysWith: { a, _ in a }))
    }

    static func record(_ s: Server) -> ServerSync.Record {
        .init(id: s.id, name: s.name, host: s.host, port: s.port, user: s.username, group: s.group, jumpHostID: s.jumpHostID,
              authKind: s.authKindRaw, pinnedHostKey: s.pinnedHostKey, isMac: s.isMac, updatedAt: .distantPast)
    }

    private static func apply(_ r: ServerSync.Record, to s: Server) {
        s.name = r.name; s.host = r.host; s.port = r.port; s.username = r.user; s.group = r.group
        s.jumpHostID = r.jumpHostID; s.authKindRaw = r.authKind; s.pinnedHostKey = r.pinnedHostKey; s.isMac = r.isMac
    }

    private func loadLast() -> [UUID: (fingerprint: String, at: Date)] {
        guard let raw = UserDefaults.standard.dictionary(forKey: lastKey) as? [String: [Any]] else { return [:] }
        var out: [UUID: (fingerprint: String, at: Date)] = [:]
        for (k, v) in raw {
            if let id = UUID(uuidString: k), v.count == 2, let fp = v[0] as? String, let t = v[1] as? Double {
                out[id] = (fp, Date(timeIntervalSince1970: t))
            }
        }
        return out
    }

    private func saveLast(_ last: [UUID: (String, Date)]) {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: last.map { ($0.key.uuidString, [$0.value.0, $0.value.1.timeIntervalSince1970] as [Any]) }),
                                  forKey: lastKey)
    }
}
