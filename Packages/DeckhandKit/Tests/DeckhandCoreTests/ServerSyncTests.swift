import Foundation
import Testing
@testable import DeckhandCore

struct ServerSyncTests {
    let a = UUID(), b = UUID()
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func rec(_ id: UUID, _ name: String, at: Date, deleted: Bool = false) -> ServerSync.Record {
        .init(id: id, name: name, host: "\(name).example.com", port: 22, user: "deploy", authKind: "key", updatedAt: at, deleted: deleted)
    }

    @Test func newerChangeWinsPerServer() {
        let local = [rec(a, "web-local", at: t0.addingTimeInterval(10)), rec(b, "db-old", at: t0)]
        let remote = [rec(a, "web-remote", at: t0), rec(b, "db-new", at: t0.addingTimeInterval(5))]
        let merged = ServerSync.merge(local: local, remote: remote, now: t0)
        #expect(merged.first { $0.id == a }?.name == "web-local")
        #expect(merged.first { $0.id == b }?.name == "db-new")
    }

    @Test func tieGoesToTheCloudSoDevicesAgree() {
        let merged = ServerSync.merge(local: [rec(a, "mine", at: t0)], remote: [rec(a, "cloud", at: t0)], now: t0)
        #expect(merged.first?.name == "cloud")
    }

    @Test func deletionTravelsAndOldMarkersExpire() {
        let gone = rec(a, "web", at: t0.addingTimeInterval(20)).tombstone(at: t0.addingTimeInterval(20))
        var merged = ServerSync.merge(local: [rec(a, "web", at: t0)], remote: [gone], now: t0.addingTimeInterval(30))
        #expect(merged.first?.deleted == true)
        merged = ServerSync.merge(local: [], remote: [gone], now: t0.addingTimeInterval(ServerSync.tombstoneLifetime + 100))
        #expect(merged.isEmpty)
    }

    @Test func localChangesGetTheCurrentTime() {
        let synced = rec(a, "web", at: t0)
        let last: [UUID: (fingerprint: String, at: Date)] = [a: (synced.fingerprint, t0), b: (rec(b, "db", at: t0).fingerprint, t0)]
        var renamed = synced; renamed.name = "web-renamed"
        let now = t0.addingTimeInterval(100)
        let out = ServerSync.localRecords(current: [renamed], lastSynced: last, now: now)
        #expect(out.first { $0.id == a }?.updatedAt == now)
        #expect(out.first { $0.id == b }?.deleted == true)   // removed here since the last sync
        let unchanged = ServerSync.localRecords(current: [synced], lastSynced: [a: (synced.fingerprint, t0)], now: now)
        #expect(unchanged.first?.updatedAt == t0)
    }

    @Test func encodingHasNoSecretsAndRoundTrips() throws {
        let data = try #require(ServerSync.encode([rec(a, "web", at: t0)]))
        let text = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!text.contains("password") && !text.contains("privatekey") && !text.contains("passphrase"))
        #expect(ServerSync.decode(data) == [rec(a, "web", at: t0)])
        #expect(ServerSync.decode(Data("junk".utf8)).isEmpty)
    }

    @Test func onlyServerSecretsTravelAndNeverWithFaceID() {
        #expect(KeychainSyncPolicy.syncs(account: "server.ABC", serversSynced: true, keysSynced: true, faceIDProtection: false))
        #expect(KeychainSyncPolicy.syncs(account: "server.ABC.passphrase", serversSynced: true, keysSynced: true, faceIDProtection: false))
        #expect(!KeychainSyncPolicy.syncs(account: "apikey.anthropic", serversSynced: true, keysSynced: true, faceIDProtection: false))
        #expect(!KeychainSyncPolicy.syncs(account: "server.ABC", serversSynced: false, keysSynced: true, faceIDProtection: false))
        #expect(!KeychainSyncPolicy.syncs(account: "server.ABC", serversSynced: true, keysSynced: false, faceIDProtection: false))
        #expect(!KeychainSyncPolicy.syncs(account: "server.ABC", serversSynced: true, keysSynced: true, faceIDProtection: true))
    }
}
