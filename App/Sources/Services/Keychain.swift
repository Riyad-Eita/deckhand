import DeckhandCore
import Foundation
import LocalAuthentication
import Security

/// Minimal Keychain wrapper for API keys, passwords and private keys. Items stay on this device. Server passwords
/// and keys get a Face ID access control when `KeyProtection` is on.
enum Keychain {
    private static let service = "de.fs223.deckhand"

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        if KeyUnlockPolicy.protects(account: account), KeyProtection.shared.enabled,
           let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil) {
            var protected = item
            protected[kSecAttrAccessControl as String] = access
            let status = SecItemAdd(protected as CFDictionary, nil)
            if status == errSecSuccess { return }
            // No passcode on this device: keep the secret rather than lose it.
            NSLog("Keychain: protected add failed (\(status)), saving without Face ID")
        }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    /// Whether an item exists, without reading it (no Face ID needed).
    static func exists(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: KeyProtection.shared.readContext,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// Whether an item was saved with the Face ID access control, read from its attributes without opening it.
    static func isProtected(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: KeyProtection.shared.readContext,
        ]
        var attrs: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &attrs) == errSecSuccess else { return false }
        // Plain items are "after first unlock"; protected ones "when unlocked" plus user presence.
        return (attrs as? [String: Any])?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
    }

    /// Saved but not readable right now (protected by Face ID and locked).
    static func isLocked(_ account: String) -> Bool { exists(account) && get(account) == nil }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: KeyProtection.shared.readContext,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
