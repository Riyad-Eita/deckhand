import DeckhandCore
import LocalAuthentication
import Observation
import SwiftUI
import UIKit

/// Optional app lock: Face ID / Touch ID with the device passcode as fallback. The lock screen lives in its own
/// window above everything (sheets and alerts included); in the app switcher the content is covered.
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()

    private(set) var isLocked = false
    private(set) var isAuthenticating = false
    private(set) var lastError: String?
    private var backgroundedAt: Date?
    private var launched = false
    private var window: UIWindow?

    private var settings: AppSettings { .shared }

    /// What the device offers: Face ID, Touch ID, Optic ID or only the passcode; nil when there's no passcode at all.
    var method: String? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return String(localized: "Passcode")
        }
    }

    func appeared() {
        guard !launched else { return }
        launched = true
        #if DEBUG
        // DECKHAND_SEED_APPLOCK=1: start with the lock on (UI tests).
        if ProcessInfo.processInfo.environment["DECKHAND_SEED_APPLOCK"] == "1" { settings.appLock = true; settings.lockDelay = 0 }
        #endif
        if AppLockPolicy.shouldLock(enabled: settings.appLock, backgroundedAt: nil, now: Date(), delay: settings.lockDelay) {
            lock()
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard settings.appLock else { return }
        switch phase {
        case .background:
            if !isAuthenticating && backgroundedAt == nil { backgroundedAt = Date() }
            showCover()
        case .inactive:
            // Also when the Face ID sheet itself is up: don't count that as leaving the app.
            if !isAuthenticating { showCover() }
        case .active:
            if isLocked { return }
            if let since = backgroundedAt,
               AppLockPolicy.shouldLock(enabled: true, backgroundedAt: since, now: Date(), delay: settings.lockDelay) {
                lock()
            } else {
                hideWindow()
            }
            backgroundedAt = nil
        @unknown default: break
        }
    }

    func lock() {
        isLocked = true
        lastError = nil
        show(LockScreenView())
        Task { await unlock() }
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let context = LAContext()
        context.localizedFallbackTitle = String(localized: "Use Passcode")
        do {
            if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Unlock Deckhand")) {
                isLocked = false
                lastError = nil
                backgroundedAt = nil
                hideWindow()
            }
        } catch let e as LAError where e.code == .userCancel || e.code == .systemCancel || e.code == .appCancel {
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Turning the lock on needs one successful check, so nobody locks themselves out.
    func confirmEnable() async -> Bool {
        let context = LAContext()
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Turn on App Lock"))) ?? false
    }

    // MARK: - Window

    private func showCover() {
        guard window == nil else { return }
        show(PrivacyCoverView())
    }

    private func show<V: View>(_ view: V) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let w = window ?? UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        let host = UIHostingController(rootView: view.environment(self))
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.makeKeyAndVisible()
        window = w
    }

    private func hideWindow() {
        window?.isHidden = true
        window = nil
    }
}

/// Shown while locked.
struct LockScreenView: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Text("Deckhand is locked").font(.title2.weight(.semibold))
                Text("Your servers and keys stay hidden until you unlock.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let error = lock.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label(String(localized: "Unlock with \(lock.method ?? String(localized: "Passcode"))"),
                          systemImage: lock.method == "Face ID" ? "faceid" : lock.method == "Touch ID" ? "touchid" : "lock.open")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(lock.isAuthenticating)
                .accessibilityIdentifier("appLock.unlock")
                .padding(.top, 8)
            }
            .padding(32)
        }
    }
}

/// Covers the content in the app switcher when the lock is on.
private struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(.secondary)
        }
    }
}
