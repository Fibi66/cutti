import Foundation
import Security

/// Thin Keychain wrapper used by `RelaySession` to persist the per-user
/// session JWT across app launches. Keychain items are written to
/// `kSecClassGenericPassword` with our bundle identifier as the service
/// so they are scoped to this app (and survive app updates but are
/// wiped on full uninstall — the same behaviour users expect from
/// "Remember me" tokens in other macOS apps).
///
/// We deliberately avoid promoting the stored blob to `kSecAttrAccessible`
/// sync-enabled values — tokens are device-local; if the user migrates to
/// a new Mac they can re-sign-in or `Restore Purchases`.
///
/// **Debug builds** additionally mirror the value to UserDefaults because
/// `swift run` re-signs the binary ad-hoc on every build. A new signature
/// creates a new Keychain ACL owner, so the previous build's Keychain
/// entry becomes unreadable and the user appears "signed out" on every
/// launch. UserDefaults is survives rebuilds (it's keyed only by the
/// sandbox container / bundle id) and the fallback kicks in only when
/// the Keychain read fails. Release builds ignore the fallback.
enum KeychainStore {
    /// Keychain service name. Fixed to the app's identity so
    /// tokens survive rebuild with debug-vs-release bundle ID drift.
    private static let service: String = "app.cutti.mac.relay"

    /// UserDefaults key prefix for the DEBUG-only mirror. Scoped by
    /// account so different accounts don't collide.
    private static func debugDefaultsKey(for account: String) -> String {
        "cutti.keychain.debug.\(account)"
    }

    static func setString(_ value: String?, for account: String) {
        #if DEBUG
        // Dev builds: skip Keychain entirely. `swift run` re-signs the
        // binary on every build, and every new signature triggers a
        // Keychain login-password prompt AND makes the previous entry
        // unreadable. UserDefaults has neither drawback.
        if let value {
            UserDefaults.standard.set(value, forKey: debugDefaultsKey(for: account))
        } else {
            UserDefaults.standard.removeObject(forKey: debugDefaultsKey(for: account))
        }
        return
        #else
        guard let value else { remove(account: account); return }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            for (k, v) in attributes { insert[k] = v }
            SecItemAdd(insert as CFDictionary, nil)
        }
        #endif
    }

    static func string(for account: String) -> String? {
        #if DEBUG
        // Dev builds: UserDefaults only (see `setString` for why).
        let v = UserDefaults.standard.string(forKey: debugDefaultsKey(for: account))
        return (v?.isEmpty == false) ? v : nil
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #endif
    }

    static func remove(account: String) {
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: debugDefaultsKey(for: account))
        return
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }
}
