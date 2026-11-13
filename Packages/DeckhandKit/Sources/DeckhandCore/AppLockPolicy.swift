import Foundation

/// When the app asks for Face ID / the passcode again.
public enum AppLockPolicy {
    /// Choices for "Lock after", in seconds. 0 locks every time the app leaves the screen.
    public static let delays: [TimeInterval] = [0, 60, 300, 900, 3600]

    /// Lock on launch (`backgroundedAt == nil`) and after the app was away at least `delay` seconds.
    /// A clock that went backwards (manual time change) locks too.
    public static func shouldLock(enabled: Bool, backgroundedAt: Date?, now: Date, delay: TimeInterval) -> Bool {
        guard enabled else { return false }
        guard let since = backgroundedAt else { return true }
        let away = now.timeIntervalSince(since)
        return away < 0 || away >= delay
    }
}

/// How long one Face ID check keeps the server passwords and keys open when they are protected.
public enum KeyUnlockPolicy {
    /// Keys stay open while the app is on screen, and for this long after it left.
    public static let window: TimeInterval = 600

    /// Which Keychain items get Face ID protection: server passwords, keys and key passphrases.
    public static func protects(account: String) -> Bool { account.hasPrefix("server.") }

    /// Open after an unlock while the app is active; after it went to the background only within `window`.
    /// A clock that went backwards locks.
    public static func isUnlocked(unlockedAt: Date?, backgroundedAt: Date?, now: Date, window: TimeInterval = window) -> Bool {
        guard let unlockedAt, now >= unlockedAt else { return false }
        guard let since = backgroundedAt else { return true }
        let away = now.timeIntervalSince(since)
        return away >= 0 && away < window
    }
}
