#if DEBUG
import Foundation
import SwiftData

/// Simulator test hook: `SIMCTL_CHILD_DECKHAND_SEED_HOST=… xcrun simctl launch …` adds a server once.
/// Variables: DECKHAND_SEED_HOST, _PORT, _USER, _KEY (private key text), _NAME, _APIKEY (Anthropic), _OPEN (open server).
enum DebugSeed {
    @MainActor
    static func apply(_ context: ModelContext) {
        let env = ProcessInfo.processInfo.environment
        if let apiKey = env["DECKHAND_SEED_APIKEY"], !apiKey.isEmpty { AppSettings.shared.apiKey = apiKey }
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
