import Foundation

/// Where the database and attachments live.
///
/// The app and its share extension must open the same files, and the only
/// place both can reach is the App Group container. A build without a signing
/// team has no group; it falls back to Application Support and the extension
/// cannot be used.
enum Storage {
    static let changedNotification = Notification.Name("org.evsyukov.lists.changed")

    static var groupIdentifier: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
              !id.hasPrefix("."), !id.isEmpty
        else { return nil }
        return id
    }

    static func directory() -> URL {
        let fm = FileManager.default
        #if DEBUG
        // Checks run against a throwaway directory, not the user's tasks.
        if let dir = ProcessInfo.processInfo.environment["LISTS_DEBUG_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        #endif
        if let group = groupIdentifier,
           let container = fm.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return container.appendingPathComponent("Lists", isDirectory: true)
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Lists", isDirectory: true)
    }

    static func openStore() throws -> Store {
        try Store.open(dir: directory().path)
    }

    /// Tells the other process (app or extension) that the data changed.
    static func announceChange() {
        DistributedNotificationCenter.default().postNotificationName(
            changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

/// Looks a string up in the app's language. The key is the English text;
/// `%@` placeholders are filled from `args`.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}

/// "1st" … "5th", used for "the n-th weekday of the month".
func ordinal(_ n: Int) -> String {
    L(["1st", "2nd", "3rd", "4th", "5th"][min(max(n, 1), 5) - 1])
}

extension AppError {
    /// Text fit for showing to the user.
    var message: String {
        switch self {
        case .NotFound: return L("Not found: it may have been deleted on another device.")
        case .Invalid(let msg): return msg
        case .Storage(let msg): return L("Could not save: %@", "\(msg)")
        case .Sync(let msg): return msg
        }
    }
}

func describe(_ error: Error) -> String {
    (error as? AppError)?.message ?? error.localizedDescription
}
