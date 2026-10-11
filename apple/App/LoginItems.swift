import AppKit
import KeyboardShortcuts
import ServiceManagement

/// What the system starts at login (R115): Lists itself, and the helper that answers the key of
/// quick entry while Lists is not running. The system keeps the state; nothing of it is stored here.
enum LoginItems {
    static let appIdentifier = "org.evsyukov.lists"
    static let helperIdentifier = "org.evsyukov.lists.helper"
    /// Posted by the helper when it lets go of the key because Lists has started.
    static let keyReleased = Notification.Name("org.evsyukov.lists.helper.keyReleased")

    #if LISTS_HELPER
    static let isHelper = true
    #else
    static let isHelper = false
    #endif

    enum Item {
        case app, helper

        var service: SMAppService {
            switch self {
            case .app: .mainApp
            case .helper: .loginItem(identifier: LoginItems.helperIdentifier)
            }
        }
    }

    enum State: Equatable { case off, on, needsApproval }

    static func state(_ status: SMAppService.Status) -> State {
        switch status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        // An item that was never turned on is "not found" to the system.
        default: .off
        }
    }

    static func state(_ item: Item) -> State { state(item.service.status) }

    static func set(_ item: Item, on: Bool) throws {
        if on { try item.service.register() } else { try item.service.unregister() }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// Lists takes the key again after the helper let go of it: a key that two programs asked for
    /// stays with the one that asked first.
    static func takeKeyBackFromHelper() {
        DistributedNotificationCenter.default().addObserver(forName: keyReleased, object: nil, queue: .main) { _ in
            KeyboardShortcuts.disable(.quickEntry)
            KeyboardShortcuts.enable(.quickEntry)
        }
    }
}
