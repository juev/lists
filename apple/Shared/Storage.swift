import Foundation

/// Where the database and attachments live.
///
/// The app and its share extension must open the same files, and the only
/// place both can reach is the App Group container. A build without a signing
/// team has no group; it falls back to Application Support and the extension
/// cannot be used.
enum Storage {
    static let changedNotification = Notification.Name("org.evsyukov.lists.changed")

    /// Where the settings are kept. The helper of quick entry (R115) has none of its own: it reads and
    /// writes those of Lists.
    static let defaults: UserDefaults = {
        #if DEBUG
        // A check has settings of its own, kept in its throwaway directory: the debug build has the
        // identifier of the installed copy, and would write into the settings of that one (#209).
        if let dir = debugDirectory, let own = UserDefaults(suiteName: dir.appendingPathComponent("settings").path) { return own }
        #endif
        #if LISTS_HELPER
        return UserDefaults(suiteName: "org.evsyukov.lists") ?? .standard
        #else
        return .standard
        #endif
    }()

    static var groupIdentifier: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
              !id.hasPrefix("."), !id.isEmpty
        else { return nil }
        return id
    }

    #if DEBUG
    /// Checks run against a throwaway directory, not the user's tasks.
    static let debugDirectory: URL? = ProcessInfo.processInfo.environment["LISTS_DEBUG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    #endif

    /// The App Group container; nil in a build without a signing team.
    static var groupContainer: URL? {
        groupIdentifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    static func directory() -> URL {
        let fm = FileManager.default
        #if DEBUG
        if let debugDirectory { return debugDirectory }
        #endif
        if let container = groupContainer {
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

/// An error as the cause in a line of the log (R102): in English, and of a system error only its domain and code,
/// because the description of an error about a file names the file.
func logged(_ error: Error) -> String {
    switch error as? AppError {
    case .NotFound?: return "not found"
    case .Invalid(let msg)?: return "invalid: \(msg)"
    case .Storage(let msg)?: return "storage: \(msg)"
    case .Sync(let msg)?: return "sync: \(msg)"
    case nil:
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
