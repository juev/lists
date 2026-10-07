import Foundation
import Security

/// The WebDAV password lives in the login keychain, the way mail and calendar
/// accounts keep theirs. The core never sees it on disk: it gets the password
/// in memory after the store is opened.
enum Keychain {
    private static let service = "org.evsyukov.lists.webdav"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// One keychain item per server and user, so switching back finds the old password.
    static func account(url: String, user: String) -> String { "\(user)@\(url)" }

    /// The access token of an ntfy server that requires sign-in (S27), one item per server.
    static func pushAccount(server: String) -> String { "ntfy:\(server)" }

    static func load(account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    static func save(_ password: String, account: String, label: String = "Lists WebDAV") throws {
        let data = Data(password.utf8)
        var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = label
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)",
            ])
        }
    }
}
