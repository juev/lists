import Foundation
import Security

/// The secrets of sync live in the login keychain, the way mail and calendar
/// accounts keep theirs. The core never sees them on disk: it gets them in
/// memory after the store is opened.
///
/// All of them are in one item, read once in a run. A build signed ad hoc has
/// another signature every time, so after an update the keychain asks again
/// for every item the app reads: with one item it asks once (#241). Before that
/// each secret had an item of its own; such an item is read the first time its
/// secret is asked for and its secret is moved into the one item.
enum Keychain {
    /// A check that has a data folder of its own has items of its own as well.
    private static let suffix: String = {
        #if DEBUG
        if Storage.debugDirectory != nil { return ".debug" }
        #endif
        return ""
    }()
    private static let service = "org.evsyukov.lists" + suffix
    private static let item = "secrets"
    /// Where each secret had an item of its own, named by its account.
    private static let formerService = "org.evsyukov.lists.webdav" + suffix

    private static let lock = NSLock()
    /// The secrets by account, once the item was read. An empty value is a secret that was removed:
    /// it is not looked for among the former items again.
    private static var secrets: [String: String]?
    /// How many items of the keychain were opened in this run: each is a question after an update.
    private(set) static var opened = 0

    private static func query(_ service: String, _ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The content of an item; nil with `errSecItemNotFound` when there is none.
    private static func read(_ service: String, _ account: String) -> (data: Data?, status: OSStatus) {
        var request = query(service, account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &found)
        if status == errSecSuccess { opened += 1 }
        return (found as? Data, status)
    }

    private static func write(_ data: Data, _ service: String, _ account: String, label: String) throws {
        var status = SecItemUpdate(query(service, account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var new = query(service, account)
            new[kSecValueData as String] = data
            new[kSecAttrLabel as String] = label
            status = SecItemAdd(new as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)",
            ])
        }
    }

    /// The secrets of the one item. Nil when the keychain did not let the item be read: nothing is
    /// written over it then, and it is asked for again the next time.
    private static func all() -> [String: String]? {
        if let secrets { return secrets }
        let (data, status) = read(service, item)
        switch status {
        case errSecSuccess:
            secrets = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        case errSecItemNotFound:
            secrets = [:]
        default:
            return nil
        }
        return secrets
    }

    private static func store(_ all: [String: String]) throws {
        try write(JSONEncoder().encode(all), service, item, label: "Lists")
        secrets = all
    }

    /// One secret per server and user, so switching back finds the old password.
    static func account(url: String, user: String) -> String { "\(user)@\(url)" }

    /// The access token of an ntfy server that requires sign-in (S27), one secret per server.
    static func pushAccount(server: String) -> String { "ntfy:\(server)" }

    static func load(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard var all = all() else { return nil }
        if let known = all[account] { return known.isEmpty ? nil : known }
        // A secret kept the former way: it is moved over, and its item stays where it is.
        guard let data = read(formerService, account).data, let secret = String(data: data, encoding: .utf8) else { return nil }
        all[account] = secret
        try? store(all)
        return secret
    }

    static func delete(account: String) {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(query(formerService, account) as CFDictionary)
        guard var all = all() else { return }
        all[account] = ""
        try? store(all)
    }

    static func save(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var all = all() else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed), userInfo: [
                NSLocalizedDescriptionKey: SecCopyErrorMessageString(errSecAuthFailed, nil) as String? ?? "OSStatus \(errSecAuthFailed)",
            ])
        }
        all[account] = secret
        try store(all)
    }

    #if DEBUG
    /// For a check: a secret kept the former way, in an item of its own.
    static func saveFormer(_ secret: String, account: String) throws {
        try write(Data(secret.utf8), formerService, account, label: "Lists WebDAV")
    }

    /// For a check: what a new run starts with, nothing read yet.
    static func forget() {
        lock.lock()
        defer { lock.unlock() }
        secrets = nil
        opened = 0
    }

    /// For a check: removes the one item and the former items of the accounts it knows.
    static func wipe(formerAccounts: [String]) {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(query(service, item) as CFDictionary)
        for account in formerAccounts { SecItemDelete(query(formerService, account) as CFDictionary) }
        secrets = nil
        opened = 0
    }
    #endif
}
