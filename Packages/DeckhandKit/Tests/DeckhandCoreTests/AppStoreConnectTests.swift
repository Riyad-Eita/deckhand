import CryptoKit
import Foundation
import Testing
@testable import DeckhandCore

struct AppStoreConnectTests {
    let key = P256.Signing.PrivateKey()
    var creds: AppStoreConnect.Credentials { .init(keyID: "ABCD123456", issuerID: "11111111-2222-3333-4444-555555555555", privateKey: key.pemRepresentation) }

    func b64(_ s: Substring) -> Data {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)!
    }

    @Test func tokenIsSignedES256() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let parts = try AppStoreConnect.token(creds, now: now).split(separator: ".")
        #expect(parts.count == 3)
        let header = try JSONSerialization.jsonObject(with: b64(parts[0])) as! [String: Any]
        let payload = try JSONSerialization.jsonObject(with: b64(parts[1])) as! [String: Any]
        #expect(header["alg"] as? String == "ES256" && header["kid"] as? String == "ABCD123456")
        #expect(payload["aud"] as? String == "appstoreconnect-v1" && payload["iat"] as? Int == 1_800_000_000 && payload["exp"] as? Int == 1_800_001_200)
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: b64(parts[2]))
        #expect(key.publicKey.isValidSignature(sig, for: Data((parts[0] + "." + parts[1]).utf8)))
    }

    @Test func rejectsWhatIsNotAKey() {
        #expect(throws: AppStoreConnect.Failure.badKey) { try AppStoreConnect.token(.init(keyID: "A", issuerID: "B", privateKey: "hello")) }
        #expect(AppStoreConnect.Credentials.keyID(fromFileName: "AuthKey_ABCD123456.p8") == "ABCD123456")
        #expect(AppStoreConnect.Credentials.keyID(fromFileName: "key.p8") == nil)
    }

    @Test func overviewParsesBuildsVersionsAndGroups() async throws {
        let builds = #"""
        {"data":[{"type":"builds","id":"b1","attributes":{"version":"4","uploadedDate":"2026-11-11T01:12:55-08:00","expired":false,"processingState":"VALID"},
          "relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"p1"}},"buildBetaDetail":{"data":{"type":"buildBetaDetails","id":"d1"}}}}],
         "included":[{"type":"preReleaseVersions","id":"p1","attributes":{"version":"1.2"}},
                     {"type":"buildBetaDetails","id":"d1","attributes":{"internalBuildState":"READY_FOR_BETA_TESTING","externalBuildState":"READY_FOR_BETA_SUBMISSION"}}]}
        """#
        let versions = #"{"data":[{"type":"appStoreVersions","id":"v1","attributes":{"platform":"IOS","versionString":"1.2","appStoreState":"WAITING_FOR_REVIEW","createdDate":"2026-11-11T13:24:35-08:00"}}]}"#
        let groups = #"{"data":[{"type":"betaGroups","id":"g1","attributes":{"name":"Team","isInternalGroup":true,"publicLinkEnabled":null}}]}"#
        let testers = #"{"data":[{"type":"betaTesters","id":"t1","attributes":{"firstName":"Sam","lastName":"Lee","email":"sam@example.com","state":"INSTALLED"}}]}"#
        let seen = Locked<[String]>([])
        let client = AppStoreConnect.Client(creds) { req in
            let path = req.url!.path
            seen.set(seen.value + [path])
            #expect(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
            let body = path.hasSuffix("/builds") ? builds : path.hasSuffix("/appStoreVersions") ? versions : path.hasSuffix("/betaGroups") ? groups : testers
            return (Data(body.utf8), 200)
        }
        let o = try await client.overview(app: "42")
        #expect(o.builds.first?.version == "1.2" && o.builds.first?.number == "4" && o.builds.first?.internalState == "READY_FOR_BETA_TESTING")
        #expect(o.builds.first?.uploaded != nil)
        #expect(o.versions.first?.state == "WAITING_FOR_REVIEW")
        #expect(o.groups.first?.isInternal == true && o.groups.first?.testers.first?.name == "Sam Lee")
        #expect(seen.value.contains("/v1/betaGroups/g1/betaTesters"))
    }

    @Test func errorsAreReadable() async {
        let client = AppStoreConnect.Client(creds) { _ in (Data(#"{"errors":[{"status":"401","detail":"x"}]}"#.utf8), 401) }
        await #expect(throws: AppStoreConnect.Failure.http(401, "x")) { try await client.apps() }
        #expect(AppStoreConnect.Failure.http(401, "x").errorDescription?.contains("key ID") == true)
    }

    @Test func reviewChangesOnlyNotifyMovesIntoNotableStates() {
        let app = AppStoreConnect.App(id: "1", name: "Shop", bundleID: "x")
        func v(_ s: String) -> AppStoreConnect.Version { .init(id: "v", version: "1.2", platform: "IOS", state: s) }
        var r = AppStoreConnect.reviewChanges(previous: [:], current: [(app, v("PREPARE_FOR_SUBMISSION"))])
        #expect(r.changes.isEmpty)                                    // first look: nothing to compare with
        r = AppStoreConnect.reviewChanges(previous: r.seen, current: [(app, v("WAITING_FOR_REVIEW"))])
        #expect(r.changes.count == 1)
        r = AppStoreConnect.reviewChanges(previous: r.seen, current: [(app, v("WAITING_FOR_REVIEW"))])
        #expect(r.changes.isEmpty)                                    // unchanged
        r = AppStoreConnect.reviewChanges(previous: r.seen, current: [(app, v("REJECTED"))])
        #expect(r.changes.first?.version.state == "REJECTED")
        #expect(AppStoreConnect.describe("PENDING_DEVELOPER_RELEASE") == "Approved, waiting for release")
    }
}

/// Live: the real API with a team key (DECKHAND_ASC_KEY_ID, DECKHAND_ASC_ISSUER, DECKHAND_ASC_KEY_FILE). Read-only.
struct LiveAppStoreConnectTests {
    @Test func readsAppsAndOverview() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let id = env["DECKHAND_ASC_KEY_ID"], let issuer = env["DECKHAND_ASC_ISSUER"], let file = env["DECKHAND_ASC_KEY_FILE"] else { return }
        let client = AppStoreConnect.Client(.init(keyID: id, issuerID: issuer, privateKey: try String(contentsOfFile: file, encoding: .utf8)))
        let apps = try await client.apps()
        #expect(!apps.isEmpty)
        for app in apps {
            let o = try await client.overview(app: app.id)
            print("\(app.name): \(o.builds.count) builds, versions \(o.versions.map { "\($0.version) \($0.state)" }), \(o.groups.count) groups, \(o.groups.map(\.testers.count).reduce(0, +)) testers")
        }
    }
}
