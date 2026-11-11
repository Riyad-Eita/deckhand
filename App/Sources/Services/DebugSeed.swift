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

    @MainActor
    static func apply(_ context: ModelContext) {
        let env = ProcessInfo.processInfo.environment
        // DECKHAND_RESET=1: start from an empty app (UI tests run one after another in the same simulator).
        if env["DECKHAND_RESET"] == "1" {
            for server in (try? context.fetch(FetchDescriptor<Server>())) ?? [] {
                Keychain.set(nil, for: server.secretAccount)
                context.delete(server)
            }
            for c in (try? context.fetch(FetchDescriptor<ConnectionRecord>())) ?? [] { context.delete(c) }
            try? context.save()
            // The Keychain survives reinstalls: forget model keys and the home card choice too.
            if env["DECKHAND_SEED_APIKEY"] == nil { AppSettings.shared.apiKey = "" }
            UserDefaults.standard.removeObject(forKey: "home.agentCardDismissed")
        }
        if let apiKey = env["DECKHAND_SEED_APIKEY"], !apiKey.isEmpty { AppSettings.shared.apiKey = apiKey }
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
