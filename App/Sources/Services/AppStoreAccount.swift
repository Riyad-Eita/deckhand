import CryptoKit
import DeckhandCore
import Foundation
import Observation

/// The user's App Store Connect API key: key ID, issuer ID and the .p8 contents, all in the Keychain.
@MainActor
@Observable
final class AppStoreAccount {
    static let shared = AppStoreAccount()
    private static let keyAccount = "asc.privateKey", idAccount = "asc.keyID", issuerAccount = "asc.issuerID"
    private static let seenKey = "asc.reviewSeen"

    private(set) var credentials: AppStoreConnect.Credentials?

    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DECKHAND_SEED_ASC"] == "demo" { demo = true; return }
        #endif
        load()
    }

    /// DEBUG: canned data for screenshots and UI tests (no network).
    private(set) var demo = false

    var isConnected: Bool { credentials != nil || demo }

    private func load() {
        if let key = Keychain.get(Self.keyAccount), let id = Keychain.get(Self.idAccount), let issuer = Keychain.get(Self.issuerAccount) {
            credentials = .init(keyID: id, issuerID: issuer, privateKey: key)
        }
    }

    var client: AppStoreConnect.Client? {
        #if DEBUG
        if demo { return AppStoreConnect.Client(Self.demoCredentials, fetch: DebugSeed.appStoreFetch) }
        #endif
        return credentials.map { AppStoreConnect.Client($0) }
    }

    /// Checks the key against App Store Connect, then keeps it.
    func connect(_ c: AppStoreConnect.Credentials) async throws -> [AppStoreConnect.App] {
        let apps = try await AppStoreConnect.Client(c).apps()
        Keychain.set(c.privateKey, for: Self.keyAccount)
        Keychain.set(c.keyID, for: Self.idAccount)
        Keychain.set(c.issuerID, for: Self.issuerAccount)
        credentials = c
        return apps
    }

    func disconnect() {
        for a in [Self.keyAccount, Self.idAccount, Self.issuerAccount] { Keychain.set(nil, for: a) }
        credentials = nil
        demo = false
        UserDefaults.standard.removeObject(forKey: Self.seenKey)
    }

    // MARK: Review notifications

    /// Looks at the newest version of every app; returns the ones whose review state moved somewhere worth telling.
    func checkReviews() async -> [(app: AppStoreConnect.App, version: AppStoreConnect.Version)] {
        guard let client, let apps = try? await client.apps() else { return [] }
        var current: [(app: AppStoreConnect.App, version: AppStoreConnect.Version)] = []
        for app in apps {
            if let v = try? await client.versions(app: app.id).first { current.append((app, v)) }
        }
        return remember(current)
    }

    /// Stores what was seen (so a screen showing the same state doesn't notify later) and returns the changes.
    @discardableResult
    func remember(_ current: [(app: AppStoreConnect.App, version: AppStoreConnect.Version)]) -> [(app: AppStoreConnect.App, version: AppStoreConnect.Version)] {
        let previous = (UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: String]) ?? [:]
        let r = AppStoreConnect.reviewChanges(previous: previous, current: current)
        UserDefaults.standard.set(r.seen, forKey: Self.seenKey)
        return r.changes
    }

    #if DEBUG
    private static let demoCredentials = AppStoreConnect.Credentials(keyID: "DEMO", issuerID: "demo", privateKey: P256Demo.pem)
    #endif
}

#if DEBUG
private enum P256Demo { static let pem = P256.Signing.PrivateKey().pemRepresentation }
#endif
