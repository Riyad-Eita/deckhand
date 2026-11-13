#if DEBUG
import DeckhandCore
import Foundation
import SwiftData

/// Simulator test hook: `SIMCTL_CHILD_DECKHAND_SEED_HOST=… xcrun simctl launch …` adds a server once.
/// Variables: DECKHAND_SEED_HOST, _PORT, _USER, _KEY (private key text), _NAME, _APIKEY (Anthropic), _OPEN (open server).
enum DebugSeed {
    /// DECKHAND_DEMO_ADDRESS="Name=shown address;…" replaces the address shown for a server (screenshots only).
    static func displayAddress(for server: Server) -> String? {
        for pair in (ProcessInfo.processInfo.environment["DECKHAND_DEMO_ADDRESS"] ?? "").split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, kv[0] == server.name { return kv[1] }
        }
        return nil
    }

    /// A reply that uses every Markdown block the chat renders.
    static let markdownReply = Message(role: .assistant, blocks: [.text("""
    ## What happens
    `FORECAST.get(city)` returns **None** for unknown cities, so the handler answers *404*:

    ```python
    def do_GET(self):
        city = self.path.strip("/").lower() or "berlin"
        temp = FORECAST.get(city)  # None for unknown cities
        self.send_response(200 if temp is not None else 404)
    ```

    | City | °C | Status |
    | --- | --- | --- |
    | berlin | 14 | 200 |
    | paris | – | 404 |

    1. Add the missing cities to `FORECAST`
    2. Or return a clear error message

    - Restart with `systemctl restart weather-api`
    - Then check `curl localhost:8080/paris`

    > Nothing was changed yet — tell me which fix you want.
    """)])

    /// A finished incident diagnosis with a suggested fix (the "Apply fix" bar).
    static let fixChat: [Message] = [
        .user("The uptime check \"Shop\" is failing: https://shop.example.com expects HTTP 200, last result: HTTP 502 after 14 ms."),
        Message(role: .assistant, blocks: [.text("""
        **nginx is up, but the app behind it isn't.** `shop.service` crashed at 10:02 after the last deploy: \
        it can't read `DATABASE_URL`, because the new `.env` was copied without it.

        ## Suggested fix
        Restore the variable from the previous release and restart the app:
        ```sh
        grep DATABASE_URL /srv/shop/releases/previous/.env >> /srv/shop/current/.env
        sudo systemctl restart shop
        ```
        """)]),
    ]

    /// An applied incident fix whose reply proposes a regression check.
    static let checkOfferChat: [Message] = [
        .user("Apply the suggested fix now."),
        Message(role: .assistant, blocks: [.text("""
        Restarted `shop`; https://shop.example.com answers 200 again.

        ```check
        name: Shop database
        url: https://example.com/
        expect: 200
        keyword: Example Domain
        ```
        """)]),
    ]

    /// DECKHAND_SEED_ASC=demo: App Store Connect answers with made-up apps (screenshots, UI tests).
    static let appStoreFetch: AppStoreConnect.Client.Fetch = { req in
        let path = req.url?.path ?? ""
        let app = path.split(separator: "/").dropFirst(2).first.map(String.init) ?? ""
        let body: String
        switch true {
        case path == "/v1/apps":
            body = #"{"data":[{"type":"apps","id":"a1","attributes":{"name":"Weather Lab","bundleId":"com.example.weather"}},{"type":"apps","id":"a2","attributes":{"name":"Shop Keeper","bundleId":"com.example.shop"}}]}"#
        case path.hasSuffix("/appStoreVersions"):
            body = app == "a1"
                ? #"{"data":[{"type":"appStoreVersions","id":"v3","attributes":{"platform":"IOS","versionString":"2.4","appStoreState":"IN_REVIEW","createdDate":"2026-11-10T09:00:00Z"}},{"type":"appStoreVersions","id":"v2","attributes":{"platform":"IOS","versionString":"2.3","appStoreState":"READY_FOR_SALE","createdDate":"2026-10-28T09:00:00Z"}},{"type":"appStoreVersions","id":"v1","attributes":{"platform":"MAC_OS","versionString":"2.3","appStoreState":"READY_FOR_SALE","createdDate":"2026-10-28T09:00:00Z"}}]}"#
                : #"{"data":[{"type":"appStoreVersions","id":"v9","attributes":{"platform":"IOS","versionString":"1.0.1","appStoreState":"PENDING_DEVELOPER_RELEASE","createdDate":"2026-11-08T09:00:00Z"}}]}"#
        case path == "/v1/builds":
            body = #"""
            {"data":[
             {"type":"builds","id":"b3","attributes":{"version":"57","uploadedDate":"2026-11-11T18:20:00Z","expired":false,"processingState":"PROCESSING"},"relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"p24"}},"buildBetaDetail":{"data":{"type":"buildBetaDetails","id":"d3"}}}},
             {"type":"builds","id":"b2","attributes":{"version":"56","uploadedDate":"2026-11-10T08:40:00Z","expired":false,"processingState":"VALID"},"relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"p24"}},"buildBetaDetail":{"data":{"type":"buildBetaDetails","id":"d2"}}}},
             {"type":"builds","id":"b1","attributes":{"version":"55","uploadedDate":"2026-10-27T16:05:00Z","expired":false,"processingState":"VALID"},"relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"p23"}},"buildBetaDetail":{"data":{"type":"buildBetaDetails","id":"d1"}}}}],
             "included":[{"type":"preReleaseVersions","id":"p24","attributes":{"version":"2.4"}},{"type":"preReleaseVersions","id":"p23","attributes":{"version":"2.3"}},
              {"type":"buildBetaDetails","id":"d3","attributes":{"internalBuildState":"PROCESSING","externalBuildState":"PROCESSING"}},
              {"type":"buildBetaDetails","id":"d2","attributes":{"internalBuildState":"IN_BETA_TESTING","externalBuildState":"BETA_APPROVED"}},
              {"type":"buildBetaDetails","id":"d1","attributes":{"internalBuildState":"IN_BETA_TESTING","externalBuildState":"IN_BETA_TESTING"}}]}
            """#
        case path.hasSuffix("/betaGroups"):
            body = #"{"data":[{"type":"betaGroups","id":"g1","attributes":{"name":"Team","isInternalGroup":true,"publicLinkEnabled":null}},{"type":"betaGroups","id":"g2","attributes":{"name":"Early birds","isInternalGroup":false,"publicLinkEnabled":true}}]}"#
        case path.hasSuffix("/customerReviews"):
            body = #"""
            {"data":[
             {"type":"customerReviews","id":"rv1","attributes":{"rating":2,"title":"Syncs twice","body":"Since the last update every forecast shows up twice in the widget.","reviewerNickname":"rainy_day","createdDate":"2026-11-09T08:00:00Z","territory":"USA"},"relationships":{"response":{"data":null}}},
             {"type":"customerReviews","id":"rv2","attributes":{"rating":5,"title":"Endlich genau","body":"Die Regenvorhersage stimmt auf die Minute. Danke!","reviewerNickname":"wetterfrosch","createdDate":"2026-11-05T08:00:00Z","territory":"DEU"},"relationships":{"response":{"data":{"type":"customerReviewResponses","id":"rs2"}}}}],
             "included":[{"type":"customerReviewResponses","id":"rs2","attributes":{"responseBody":"Danke dir!","state":"PUBLISHED"}}]}
            """#
        case path.hasSuffix("/customerReviewResponses") || path.contains("/customerReviewResponses/"):
            return (Data(), req.httpMethod == "DELETE" ? 204 : 201)
        case path.hasSuffix("/betaTesters"):
            body = path.contains("g1")
                ? #"{"data":[{"type":"betaTesters","id":"t1","attributes":{"firstName":"Alex","lastName":"Morgan","email":"alex@example.com","state":"INSTALLED"}},{"type":"betaTesters","id":"t2","attributes":{"firstName":"Sam","lastName":"Lee","email":"sam@example.com","state":"INSTALLED"}}]}"#
                : #"{"data":[{"type":"betaTesters","id":"t3","attributes":{"firstName":"Robin","lastName":"Park","email":"robin@example.com","state":"INSTALLED"}},{"type":"betaTesters","id":"t4","attributes":{"firstName":"","lastName":"","email":"kim@example.com","state":"INVITED"}}]}"#
        default:
            body = #"{"data":[]}"#
        }
        try? await Task.sleep(for: .milliseconds(300))
        return (Data(body.utf8), 200)
    }

    /// A "Plan first" request answered with a plan.
    static let planChat: [Message] = [
        .user(PlanMode.wrap("Move the shop to port 8081")),
        Message(role: .assistant, blocks: [.text("""
        The shop runs behind nginx on port 8080; I'd switch the upstream and reload.

        ```plan
        - Back up /etc/nginx/sites-available/shop
        - Change the upstream port from 8080 to 8081
        - Restart the shop service on port 8081
        - Test with nginx -t, then reload nginx
        ```
        Risk: a typo stops nginx from reloading; the backup makes it quick to undo.
        """)]),
    ]

    /// A long task whose first steps were summarized.
    static let compactedChat: [Message] = [
        .user("Upgrade the shop to Node 22."),
        Message(role: .assistant, blocks: [.text("Installed Node 22 and rebuilt the app.")]),
        .user("Restart it."),
        Message(role: .assistant, blocks: [.text("Restarted `shop`; it answers again.")]),
    ]

    /// A finished chat whose tool output and reply contain made-up secrets (built at runtime, not real keys).
    static var secretsChat: [Message] {
        let token = "ghp_" + String(repeating: "dEmO", count: 9)
        let key = "sk-proj-" + String(repeating: "Demo_", count: 6)
        let call = ToolCall(id: "seed-env", name: "run_command", input: ["command": "cat .env"])
        return [
            .user("Why can't the app reach the database?"),
            Message(role: .assistant, blocks: [.text("Let me look at the settings."), .toolUse(call)]),
            Message(role: .user, blocks: [.toolResult(ToolResult(toolUseID: call.id, content: """
            DATABASE_URL=postgres://app:S3cretDbPass@db:5432/weather
            OPENAI_API_KEY=\(key)
            GITHUB_TOKEN=\(token)
            PORT=8080
            """))]),
            Message(role: .assistant, blocks: [.text("""
            The app points at host **db**, which doesn't resolve on this server. Your `GITHUB_TOKEN` (\(token)) is fine.

            Change `DATABASE_URL` to use `localhost` and restart the app.
            """)]),
        ]
    }

    /// Prompt the next opened chat sends automatically.
    @MainActor static var pendingPrompt: String?
    /// DECKHAND_SEED_RUN="codex|prompt" (or ownKey|…, claudeCode|…, terminal|): open the first server and start it.
    @MainActor static var pendingRun: (engine: String, prompt: String)? = {
        guard let raw = ProcessInfo.processInfo.environment["DECKHAND_SEED_RUN"], let bar = raw.firstIndex(of: "|") else { return nil }
        return (String(raw[..<bar]), String(raw[raw.index(after: bar)...]))
    }()

    /// When this launch started seeding: servers created after it are this launch's, not leftovers being deleted.
    @MainActor static var seededAt = Date.distantPast

    @MainActor
    static func apply(_ context: ModelContext) {
        seededAt = Date().addingTimeInterval(-1)
        let env = ProcessInfo.processInfo.environment
        // DECKHAND_RESET=1: start from an empty app (UI tests run one after another in the same simulator).
        if env["DECKHAND_RESET"] == "1" {
            // Tasks and plain chats first, then servers: deleting a task twice (once by the server's cascade) made
            // the save fail, and then nothing was reset.
            for thread in (try? context.fetch(FetchDescriptor<ChatThread>())) ?? [] { context.delete(thread) }
            for server in (try? context.fetch(FetchDescriptor<Server>())) ?? [] {
                Keychain.set(nil, for: server.secretAccount)
                context.delete(server)
            }
            for c in (try? context.fetch(FetchDescriptor<ConnectionRecord>())) ?? [] { context.delete(c) }
            do { try context.save() } catch { NSLog("DECKHAND_RESET: save failed: \(error)") }
            // The Keychain survives reinstalls: forget model keys and the home card choice too.
            if env["DECKHAND_SEED_APIKEY"] == nil { AppSettings.shared.apiKey = "" }
            UserDefaults.standard.removeObject(forKey: "home.agentCardDismissed")
        }
        if let apiKey = env["DECKHAND_SEED_APIKEY"], !apiKey.isEmpty { AppSettings.shared.apiKey = apiKey }
        // DECKHAND_SEED_HTTP=1: one demo collection for the HTTP client (replaces what's there).
        if env["DECKHAND_SEED_HTTP"] == "1" {
            typealias H = HTTPClient
            let token = H.Variable(name: "token", value: "", secret: true)
            var c = H.Collection(name: "Example API", requests: [
                H.Request(name: "Home page", url: "{{base}}/"),
                H.Request(name: "Create item", method: .POST, url: "{{base}}/items",
                          headers: [.init(name: "Accept", value: "application/json")],
                          body: "{\n  \"name\": \"Deck chair\",\n  \"stock\": 12\n}", auth: .bearer("{{token}}")),
                H.Request(name: "Delete item", method: .DELETE, url: "{{base}}/items/42", auth: .bearer("{{token}}")),
            ], environments: [
                H.Environment(name: "Production", variables: [.init(name: "base", value: "https://example.com"), token]),
                H.Environment(name: "Local on the server", variables: [.init(name: "base", value: "http://localhost:8080")]),
            ])
            c.activeEnvironment = c.environments[0].id
            HTTPStore.shared.collections = [c]
            HTTPStore.shared.setSecret("demo-token", for: token)
        }
        // DECKHAND_SEED_CONNECTION="Name|https://url" adds an HTTP MCP connection once.
        if let raw = env["DECKHAND_SEED_CONNECTION"], let bar = raw.firstIndex(of: "|") {
            let name = String(raw[..<bar]), url = String(raw[raw.index(after: bar)...])
            let have = (try? context.fetch(FetchDescriptor<ConnectionRecord>())) ?? []
            if !have.contains(where: { $0.url == url }) { context.insert(ConnectionRecord(name: name, kind: "http", url: url)) }
        }
        // DECKHAND_SEED_EXTRA="Name|host|user;Name2|host2|user2" adds display-only servers (for screenshots),
        // after the real seeded server so that one stays first in the list.
        defer { seedExtras(env, context) }
        func seedExtras(_ env: [String: String], _ context: ModelContext) {
        for entry in (env["DECKHAND_SEED_EXTRA"] ?? "").split(separator: ";") {
            let p = entry.split(separator: "|").map(String.init)
            guard p.count == 3 else { continue }
            let have = (try? context.fetch(FetchDescriptor<Server>())) ?? []
            if !have.contains(where: { $0.name == p[0] }) {
                context.insert(Server(name: p[0], host: p[1], username: p[2], authKind: .key))
            }
        }
        try? context.save()
        }
        guard let host = env["DECKHAND_SEED_HOST"], let user = env["DECKHAND_SEED_USER"],
              let key = env["DECKHAND_SEED_KEY"] ?? env["DECKHAND_SEED_PASSWORD"] else { return }
        let existing = (try? context.fetch(FetchDescriptor<Server>())) ?? []
        if existing.contains(where: { $0.host == host && $0.username == user }) { return }
        let server = Server(
            name: env["DECKHAND_SEED_NAME"] ?? host, host: host,
            port: Int(env["DECKHAND_SEED_PORT"] ?? "22") ?? 22, username: user,
            authKind: env["DECKHAND_SEED_PASSWORD"] != nil ? .password : .key)
        context.insert(server)
        Keychain.set(key, for: server.secretAccount)
        try? context.save()
    }

    @MainActor
    static func runIntent(_ spec: String) async {
        let out = FileManager.default.temporaryDirectory.appending(path: "intent-result.txt")
        do {
            guard let entity = try ServerQuery().allEntities().first else { throw IntentError.serverGone }
            var text = ""
            if spec == "status" {
                var intent = ServerStatusIntent(); intent.server = entity
                let r = try await intent.perform()
                text = r.value ?? ""
            } else if spec.hasPrefix("run:") {
                var intent = RunCommandIntent(); intent.server = entity; intent.command = String(spec.dropFirst(4))
                let r = try await intent.perform()
                text = r.value ?? ""
            }
            try ("OK " + text).write(to: out, atomically: true, encoding: .utf8)
        } catch {
            try? ("ERROR \(error)").write(to: out, atomically: true, encoding: .utf8)
        }
    }
}
#endif
