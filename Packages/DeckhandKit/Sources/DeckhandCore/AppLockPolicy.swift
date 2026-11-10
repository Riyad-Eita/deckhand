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
