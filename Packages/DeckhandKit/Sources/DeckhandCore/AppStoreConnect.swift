import CryptoKit
import Foundation

/// App Store Connect from the phone: builds, TestFlight groups and testers, review state — signed with the user's own
/// API key (an ES256 token made on the device; the key never leaves it).
public enum AppStoreConnect {
    public struct Credentials: Sendable, Hashable {
        public var keyID: String
        public var issuerID: String
        /// The `.p8` file's contents (PEM, PKCS#8).
        public var privateKey: String
        public init(keyID: String, issuerID: String, privateKey: String) {
            self.keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.issuerID = issuerID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.privateKey = privateKey
        }

        /// The key ID is part of Apple's file name: `AuthKey_<KEYID>.p8`.
        public static func keyID(fromFileName name: String) -> String? {
            guard let r = name.range(of: #"AuthKey_([A-Z0-9]{8,12})\.p8"#, options: .regularExpression) else { return nil }
            return String(name[r].dropFirst(8).dropLast(3))
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case badKey, http(Int, String)
        public var errorDescription: String? {
            switch self {
            case .badKey: "This isn't an App Store Connect API key (.p8)."
            case .http(401, _): "App Store Connect didn't accept the key. Check the key ID and issuer ID."
            case .http(403, _): "This key isn't allowed to read that. Use a key with the Developer, App Manager or Admin role."
            case .http(let code, let detail): "App Store Connect answered \(code)\(detail.isEmpty ? "" : ": " + detail)"
            }
        }
    }

    // MARK: Token

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A token valid for 20 minutes (Apple's maximum).
    public static func token(_ c: Credentials, now: Date = Date()) throws -> String {
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: c.privateKey.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure.badKey
        }
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": c.keyID, "typ": "JWT"], options: .sortedKeys)
        let iat = Int(now.timeIntervalSince1970)
        let payload = try JSONSerialization.data(
            withJSONObject: ["iss": c.issuerID, "iat": iat, "exp": iat + 1200, "aud": "appstoreconnect-v1"] as [String: Any], options: .sortedKeys)
        let input = base64URL(header) + "." + base64URL(payload)
        let signature = try key.signature(for: Data(input.utf8))
        return input + "." + base64URL(signature.rawRepresentation)
    }

    // MARK: Models

    public struct App: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var bundleID: String
    }

    public struct Build: Sendable, Hashable, Identifiable {
        public var id: String
        public var number: String
        public var version: String
        public var uploaded: Date?
        /// PROCESSING, FAILED, INVALID, VALID
        public var processing: String
        public var expired: Bool
        public var internalState: String?
        public var externalState: String?
    }

    public struct Version: Sendable, Hashable, Identifiable {
        public var id: String
        public var version: String
        public var platform: String
        public var state: String
        public var created: Date?
    }

    public struct Tester: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var email: String
        public var state: String
    }

    public struct Group: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var isInternal: Bool
        public var publicLink: Bool
        public var testers: [Tester] = []
    }

    public struct Overview: Sendable, Hashable {
        public var builds: [Build] = []
        public var versions: [Version] = []
        public var groups: [Group] = []
    }

    // MARK: State names

    /// A short, plain name for a review / release state.
    public static func describe(_ state: String) -> String {
        switch state {
        case "PREPARE_FOR_SUBMISSION": "Preparing"
        case "READY_FOR_REVIEW", "WAITING_FOR_REVIEW": "Waiting for review"
        case "IN_REVIEW": "In review"
        case "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE": "Approved, waiting for release"
        case "PROCESSING_FOR_APP_STORE", "PROCESSING_FOR_DISTRIBUTION": "Processing for the App Store"
        case "READY_FOR_SALE", "READY_FOR_DISTRIBUTION": "On the App Store"
        case "REJECTED": "Rejected"
        case "METADATA_REJECTED": "Metadata rejected"
        case "DEVELOPER_REJECTED": "Pulled back"
        case "INVALID_BINARY": "Invalid build"
        case "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE": "Removed from sale"
        case "ACCEPTED": "Accepted"
        case "WAITING_FOR_EXPORT_COMPLIANCE", "MISSING_EXPORT_COMPLIANCE": "Needs export compliance"
        case "READY_FOR_BETA_TESTING": "Ready to test"
        case "IN_BETA_TESTING": "Testing"
        case "READY_FOR_BETA_SUBMISSION": "Not submitted for external testing"
        case "WAITING_FOR_BETA_REVIEW": "Waiting for beta review"
        case "IN_BETA_REVIEW": "In beta review"
        case "BETA_REJECTED": "Beta rejected"
        case "BETA_APPROVED": "Beta approved"
        case "IN_EXPORT_COMPLIANCE_REVIEW": "Export compliance review"
        case "PROCESSING_EXCEPTION": "Processing failed"
        case "EXPIRED": "Expired"
        case "INSTALLED": "Installed"
        case "ACCEPTED_INVITE", "ACCEPTED_INVITATION": "Accepted"
        case "INVITED": "Invited"
        case "NOT_INVITED": "Not invited"
        case "REVOKED": "Revoked"
        default: state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public enum Tone: Sendable { case good, waiting, bad, neutral }

    public static func tone(_ state: String) -> Tone {
        switch state {
        case "READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "ACCEPTED",
             "READY_FOR_BETA_TESTING", "IN_BETA_TESTING", "BETA_APPROVED", "INSTALLED", "VALID": .good
        case "WAITING_FOR_REVIEW", "READY_FOR_REVIEW", "IN_REVIEW", "PROCESSING_FOR_APP_STORE", "PROCESSING_FOR_DISTRIBUTION",
             "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW", "PROCESSING", "INVITED", "WAITING_FOR_EXPORT_COMPLIANCE",
             "IN_EXPORT_COMPLIANCE_REVIEW": .waiting
        case "REJECTED", "METADATA_REJECTED", "INVALID_BINARY", "BETA_REJECTED", "PROCESSING_EXCEPTION", "FAILED", "INVALID",
             "MISSING_EXPORT_COMPLIANCE": .bad
        default: .neutral
        }
    }

    /// States worth a notification when a version moves into them.
    public static func isNotable(_ state: String) -> Bool {
        ["WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "READY_FOR_SALE",
         "READY_FOR_DISTRIBUTION", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY", "ACCEPTED"].contains(state)
    }

    // MARK: JSON:API

    struct Resource: Decodable {
        var id: String
        var type: String
        var attributes: [String: JSONValue]?
        var relationships: [String: Relationship]?
        struct Relationship: Decodable { var data: Link? }
        struct Link: Decodable { var id: String; var type: String }
        func string(_ k: String) -> String? { attributes?[k]?.stringValue }
        func bool(_ k: String) -> Bool? { if case .bool(let b)? = attributes?[k] { b } else { nil } }
        func date(_ k: String) -> Date? { string(k).flatMap(AppStoreConnect.parseDate) }
    }

    struct Document: Decodable {
        var data: [Resource]
        var included: [Resource]?
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    static func decode(_ data: Data) throws -> Document { try JSONDecoder().decode(Document.self, from: data) }

    static func apps(_ d: Document) -> [App] {
        d.data.map { App(id: $0.id, name: $0.string("name") ?? $0.id, bundleID: $0.string("bundleId") ?? "") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func builds(_ d: Document) -> [Build] {
        let inc = Dictionary((d.included ?? []).map { ("\($0.type)/\($0.id)", $0) }, uniquingKeysWith: { a, _ in a })
        func rel(_ r: Resource, _ k: String) -> Resource? {
            r.relationships?[k]?.data.flatMap { inc["\($0.type)/\($0.id)"] }
        }
        return d.data.map { b in
            let beta = rel(b, "buildBetaDetail")
            return Build(id: b.id, number: b.string("version") ?? "?", version: rel(b, "preReleaseVersion")?.string("version") ?? "",
                         uploaded: b.date("uploadedDate"), processing: b.string("processingState") ?? "", expired: b.bool("expired") ?? false,
                         internalState: beta?.string("internalBuildState"), externalState: beta?.string("externalBuildState"))
        }
    }

    static func versions(_ d: Document) -> [Version] {
        d.data.map {
            Version(id: $0.id, version: $0.string("versionString") ?? "", platform: $0.string("platform") ?? "IOS",
                    state: $0.string("appStoreState") ?? $0.string("appVersionState") ?? "", created: $0.date("createdDate"))
        }
    }

    static func groups(_ d: Document) -> [Group] {
        d.data.map { Group(id: $0.id, name: $0.string("name") ?? "", isInternal: $0.bool("isInternalGroup") ?? false, publicLink: $0.bool("publicLinkEnabled") ?? false) }
    }

    static func testers(_ d: Document) -> [Tester] {
        d.data.map {
            let name = [$0.string("firstName"), $0.string("lastName")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            return Tester(id: $0.id, name: name, email: $0.string("email") ?? "", state: $0.string("state") ?? "")
        }
    }

    // MARK: Client

    public struct Client: Sendable {
        public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)
        let credentials: Credentials
        let fetch: Fetch
        static let base = "https://api.appstoreconnect.apple.com"

        public init(_ credentials: Credentials, fetch: Fetch? = nil) {
            self.credentials = credentials
            self.fetch = fetch ?? { req in
                let (data, resp) = try await URLSession.shared.data(for: req)
                return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
            }
        }

        func get(_ path: String) async throws -> Document {
            try decode(try await send("GET", path))
        }

        /// One request; the body as JSON. Errors carry App Store Connect's own detail text.
        @discardableResult
        func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
            guard let url = URL(string: Self.base + path) else { throw Failure.http(0, "bad path") }
            var req = URLRequest(url: url, timeoutInterval: 30)
            req.httpMethod = method
            req.setValue("Bearer " + (try token(credentials)), forHTTPHeaderField: "Authorization")
            if let body {
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, code) = try await fetch(req)
            guard (200..<300).contains(code) else {
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { ($0["errors"] as? [[String: Any]])?.first?["detail"] as? String } ?? ""
                throw Failure.http(code, detail)
            }
            return data
        }

        /// The newest reviews (up to 100) with the developer's response, if any.
        public func reviews(app: String) async throws -> [Review] {
            AppStoreConnect.reviews(try await get("/v1/apps/\(app)/customerReviews?sort=-createdDate&limit=100&include=response"
                + "&fields[customerReviewResponses]=responseBody,lastModifiedDate,state"))
        }

        /// Posts the reply; an existing one is deleted first (App Store Connect keeps one per review).
        public func reply(to review: Review, body: String) async throws {
            if let existing = review.response { try await send("DELETE", "/v1/customerReviewResponses/\(existing.id)") }
            try await send("POST", "/v1/customerReviewResponses", body: [
                "data": [
                    "type": "customerReviewResponses",
                    "attributes": ["responseBody": body],
                    "relationships": ["review": ["data": ["type": "customerReviews", "id": review.id]]],
                ] as [String: Any],
            ])
        }

        public func apps() async throws -> [App] {
            AppStoreConnect.apps(try await get("/v1/apps?fields[apps]=name,bundleId&limit=200"))
        }

        public func versions(app: String) async throws -> [Version] {
            AppStoreConnect.versions(try await get(
                "/v1/apps/\(app)/appStoreVersions?limit=5&fields[appStoreVersions]=versionString,appStoreState,appVersionState,platform,createdDate"))
        }

        public func overview(app: String) async throws -> Overview {
            async let b = get("/v1/builds?filter[app]=\(app)&sort=-uploadedDate&limit=15"
                + "&fields[builds]=version,uploadedDate,processingState,expired,preReleaseVersion,buildBetaDetail"
                + "&include=preReleaseVersion,buildBetaDetail&fields[preReleaseVersions]=version"
                + "&fields[buildBetaDetails]=internalBuildState,externalBuildState")
            async let v = versions(app: app)
            async let g = get("/v1/apps/\(app)/betaGroups?fields[betaGroups]=name,isInternalGroup,publicLinkEnabled&limit=50")
            var o = Overview(builds: AppStoreConnect.builds(try await b), versions: try await v, groups: AppStoreConnect.groups(try await g))
            for i in o.groups.indices {
                o.groups[i].testers = AppStoreConnect.testers(try await get(
                    "/v1/betaGroups/\(o.groups[i].id)/betaTesters?fields[betaTesters]=firstName,lastName,email,state&limit=200"))
            }
            return o
        }
    }

    // MARK: Customer reviews

    public struct Review: Sendable, Hashable, Identifiable {
        public struct Response: Sendable, Hashable { public var id: String; public var body: String; public var state: String }
        public var id: String
        public var rating: Int
        public var title: String
        public var body: String
        public var nickname: String
        public var date: Date?
        /// ISO 3166 alpha-3, e.g. `DEU`.
        public var territory: String
        public var response: Response?
    }

    static func reviews(_ d: Document) -> [Review] {
        let inc = Dictionary((d.included ?? []).map { ("\($0.type)/\($0.id)", $0) }, uniquingKeysWith: { a, _ in a })
        return d.data.map { r in
            let resp = r.relationships?["response"]?.data.flatMap { inc["\($0.type)/\($0.id)"] }
            return Review(id: r.id, rating: r.attributes?["rating"]?.intValue ?? 0, title: r.string("title") ?? "",
                          body: r.string("body") ?? "", nickname: r.string("reviewerNickname") ?? "", date: r.date("createdDate"),
                          territory: r.string("territory") ?? "",
                          response: resp.map { Review.Response(id: $0.id, body: $0.string("responseBody") ?? "", state: $0.string("state") ?? "") })
        }
    }

    /// Instructions for drafting a reply (on-device model or the user's key).
    public static let replyInstructions = """
    You write the developer's public reply to an App Store review. Use the review's language. Be warm, concrete and \
    short (2–4 sentences, under 600 characters): thank them, answer the actual point, say what changed or what's \
    planned only if the developer's notes say so, and invite them to get in touch for bugs. No promises, no \
    marketing phrases, no emojis, no signature. Answer with the reply text only.
    """

    public static func replyPrompt(_ r: Review, app: String, notes: String = "") -> String {
        """
        App: \(app)
        Rating: \(r.rating) of 5\(r.territory.isEmpty ? "" : " (store \(r.territory))")
        Title: \(r.title)
        Review: \(r.body)
        \(notes.isEmpty ? "" : "Developer's notes: \(notes)")
        """
    }

    // MARK: Review watch

    /// Compares the newest version of each app with what was seen before. Returns the changes worth a notification
    /// and the new state map (`<app id>` → `<version> <state>`).
    public static func reviewChanges(previous: [String: String], current: [(app: App, version: Version)])
        -> (changes: [(app: App, version: Version)], seen: [String: String]) {
        var seen = previous
        var changes: [(App, Version)] = []
        for (app, v) in current {
            let key = "\(v.version) \(v.state)"
            if let old = previous[app.id], old != key, isNotable(v.state) { changes.append((app, v)) }
            seen[app.id] = key
        }
        return (changes, seen)
    }
}
