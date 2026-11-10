#if DEBUG
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
}
#endif
