#if DEBUG
import Foundation
import SwiftData

/// Simulator test hook: `SIMCTL_CHILD_DECKHAND_SEED_HOST=… xcrun simctl launch …` adds a server once.
/// Variables: DECKHAND_SEED_HOST, _PORT, _USER, _KEY (private key text), _NAME, _APIKEY (Anthropic), _OPEN (open server).
enum DebugSeed {
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
        if let apiKey = env["DECKHAND_SEED_APIKEY"], !apiKey.isEmpty { AppSettings.shared.apiKey = apiKey }
        // DECKHAND_SEED_CONNECTION="Name|https://url" adds an HTTP MCP connection once.
        if let raw = env["DECKHAND_SEED_CONNECTION"], let bar = raw.firstIndex(of: "|") {
            let name = String(raw[..<bar]), url = String(raw[raw.index(after: bar)...])
            let have = (try? context.fetch(FetchDescriptor<ConnectionRecord>())) ?? []
            if !have.contains(where: { $0.url == url }) { context.insert(ConnectionRecord(name: name, kind: "http", url: url)) }
        }
        guard let host = env["DECKHAND_SEED_HOST"], let user = env["DECKHAND_SEED_USER"],
              let key = env["DECKHAND_SEED_KEY"] else { return }
        let existing = (try? context.fetch(FetchDescriptor<Server>())) ?? []
        if existing.contains(where: { $0.host == host && $0.username == user }) { return }
        let server = Server(
            name: env["DECKHAND_SEED_NAME"] ?? host, host: host,
            port: Int(env["DECKHAND_SEED_PORT"] ?? "22") ?? 22, username: user, authKind: .key)
        context.insert(server)
        Keychain.set(key, for: server.secretAccount)
        try? context.save()
    }
}
#endif
