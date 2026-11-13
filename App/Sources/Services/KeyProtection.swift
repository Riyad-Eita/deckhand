import DeckhandCore
import Foundation
import LocalAuthentication
import UIKit

/// Optional Face ID for the server passwords and keys themselves: the Keychain items carry an access control
/// (user presence), so they can't be read without a check — not by someone holding the unlocked phone, and not by
/// background work. One check keeps them open while the app is used and for `KeyUnlockPolicy.window` after it left.
final class KeyProtection: @unchecked Sendable {
    static let shared = KeyProtection()
    static let defaultsKey = "keys.protected"

    enum Failure: LocalizedError {
        case locked
        var errorDescription: String? {
            String(localized: "Server keys are locked. Open Deckhand and unlock them with Face ID.")
        }
    }

    private let lock = NSLock()
    private var context: LAContext = KeyProtection.silentContext()
    private var unlockedAt: Date?
    private var backgroundedAt: Date?

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.defaultsKey) }

    /// The context Keychain reads go through. It never shows UI itself: unless it was evaluated (unlocked), reads
    /// of protected items fail instead of prompting.
    var readContext: LAContext {
        lock.withLock {
            if !KeyUnlockPolicy.isUnlocked(unlockedAt: unlockedAt, backgroundedAt: backgroundedAt, now: Date()), unlockedAt != nil {
                context.invalidate(); context = Self.silentContext(); unlockedAt = nil; backgroundedAt = nil
            }
            return context
        }
    }

    var isUnlocked: Bool {
        lock.withLock { KeyUnlockPolicy.isUnlocked(unlockedAt: unlockedAt, backgroundedAt: backgroundedAt, now: Date()) }
    }

    private static func silentContext() -> LAContext {
        let c = LAContext()
        c.interactionNotAllowed = true
        return c
    }

    /// One Face ID / passcode check that opens the protected items for a while. True when already open.
    @MainActor
    func unlock(reason: String = String(localized: "Unlock your server keys")) async -> Bool {
        if isUnlocked { return true }
        guard UIApplication.shared.applicationState != .background else { return false }
        let fresh = LAContext()
        fresh.localizedFallbackTitle = String(localized: "Use Passcode")
        guard (try? await fresh.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else { return false }
        fresh.interactionNotAllowed = true
        lock.withLock {
            context.invalidate()
            context = fresh
            unlockedAt = Date()
            backgroundedAt = nil
        }
        return true
    }

    /// Before using a server's credentials: unlocks when protection is on (only possible with the app on screen).
    @MainActor
    func ensureUnlocked() async throws {
        guard enabled else { return }
        if await !unlock() { throw Failure.locked }
    }

    func lockNow() {
        lock.withLock { context.invalidate(); context = Self.silentContext(); unlockedAt = nil; backgroundedAt = nil }
    }

    func didEnterBackground() { lock.withLock { if backgroundedAt == nil { backgroundedAt = Date() } } }

    func didBecomeActive() {
        _ = readContext // drops an expired unlock
        lock.withLock { if unlockedAt != nil { backgroundedAt = nil } }
    }

    /// Turns protection on or off and re-saves the given items with or without the access control. Needs one check
    /// (also to read items that are protected now). Items that can't be read are left as they are.
    @MainActor
    func setEnabled(_ on: Bool, accounts: [String]) async -> Bool {
        guard await unlock(reason: on ? String(localized: "Protect your server keys") : String(localized: "Remove Face ID from your server keys")) else {
            return false
        }
        let values = accounts.compactMap { a in Keychain.get(a).map { (a, $0) } }
        UserDefaults.standard.set(on, forKey: Self.defaultsKey)
        for (a, v) in values { Keychain.set(v, for: a) }
        return true
    }

    /// Whether this device can protect items at all (a passcode is set).
    static var available: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) }
}
