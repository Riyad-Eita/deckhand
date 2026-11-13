import DeckhandCore
import Foundation
import FoundationModels

/// Small AI jobs (explanations, titles): Apple's on-device model when this iPhone has Apple Intelligence — free and
/// private — otherwise the user's own key.
@MainActor
enum QuickAI {
    enum Source: Equatable {
        case onDevice
        case key(model: String)
    }

    static var onDeviceAvailable: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DECKHAND_SEED_NO_ONDEVICE"] == "1" { return false }
        #endif
        return SystemLanguageModel.default.isAvailable
    }

    static var isAvailable: Bool { onDeviceAvailable || AppSettings.shared.isConfigured }

    /// Runs one prompt; `keyAllowed` false means on-device only (for things nobody asked for, like titles).
    static func run(_ instructions: String, _ prompt: String, keyAllowed: Bool = true) async throws -> (text: String, source: Source)? {
        #if DEBUG
        if let canned = ProcessInfo.processInfo.environment["DECKHAND_SEED_EXPLAIN"] { return (canned, .onDevice) }
        #endif
        var onDeviceError: Error?
        if onDeviceAvailable {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let reply = try await session.respond(to: prompt)
                return (reply.content, .onDevice)
            } catch {
                // Still downloading, busy, or the input was too long for it: the key can take over.
                onDeviceError = error
            }
        }
        guard keyAllowed, AppSettings.shared.isConfigured else {
            if onDeviceError != nil { throw OnDeviceFailure() }
            return nil
        }
        let config = AppSettings.shared.providerConfig
        let text = try await AppProviders.make(config).complete(system: instructions, prompt: prompt, maxTokens: 800)
        return (text, .key(model: config.model))
    }

    struct OnDeviceFailure: LocalizedError {
        var errorDescription: String? {
            String(localized: "The on-device model couldn't answer right now (Apple Intelligence may still be getting ready). Add a model key in Settings to use it as a fallback.")
        }
    }

    /// A short title for a task, on-device only (free); nil when the model isn't there.
    static func title(for request: String) async -> String? {
        guard onDeviceAvailable || ProcessInfo.processInfo.environment["DECKHAND_SEED_EXPLAIN"] != nil else { return nil }
        guard let r = try? await run(Explain.titleInstructions, String(request.prefix(2_000)), keyAllowed: false) else { return nil }
        let t = Explain.cleanTitle(r.text)
        return t.isEmpty ? nil : t
    }
}
