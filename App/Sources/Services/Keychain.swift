import DeckhandCore
import Foundation
import LocalAuthentication
import Security

/// Minimal Keychain wrapper for API keys, passwords and private keys. Items stay on this device, except server
/// secrets when the user syncs them with iCloud Keychain (`KeychainSyncPolicy`). Server passwords and keys get a
/// Face ID access control when `KeyProtection` is on (and then never sync).
enum Keychain {
    private static let service = "de.fs223.deckhand"

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var any = base
        any[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny   // the local and the iCloud copy
        let syncs = KeychainSyncPolicy.syncs(account: account, serversSynced: UserDefaults.standard.bool(forKey: "sync.servers"),
                                             keysSynced: UserDefaults.standard.bool(forKey: "sync.keys"),
                                             faceIDProtection: KeyProtection.shared.enabled)
        // Removing a secret, or writing the shared copy, replaces both. A device that keeps its secret locally only
        // replaces its own copy: the iCloud one stays for the user's other devices.
        SecItemDelete((value?.isEmpty ?? true) || syncs ? any as CFDictionary : base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = base
        if syncs {
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrSynchronizable as String] = true
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock   // iCloud Keychain, end-to-end encrypted
            if SecItemAdd(item as CFDictionary, nil) == errSecSuccess { return }
            item[kSecAttrSynchronizable as String] = nil
        }
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
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
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
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseAuthenticationContext as String: KeyProtection.shared.readContext,
        ]
        var attrs: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &attrs) == errSecSuccess else { return false }
        // Plain items are "after first unlock"; protected ones "when unlocked" plus user presence.
        return (attrs as? [String: Any])?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
    }

    /// Saved but not readable right now (protected by Face ID and locked).
    static func isLocked(_ account: String) -> Bool { exists(account) && get(account) == nil }

    /// This device's own copy first, else the one from iCloud Keychain.
    static func get(_ account: String) -> String? {
        read(account, synchronizable: false) ?? read(account, synchronizable: true)
    }

    private static func read(_ account: String, synchronizable: Bool) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: synchronizable,
            kSecUseAuthenticationContext as String: KeyProtection.shared.readContext,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Saves every server secret again under the current rules (after the sync setting or Face ID protection
    /// changed), so each one moves to iCloud Keychain or back to this device only.
    @MainActor static func resaveServerSecrets(_ accounts: [String]) {
        for account in accounts {
            for a in [account, account + ".passphrase"] {
                if let value = get(a) { set(value, for: a) }
            }
        }
    }
}
