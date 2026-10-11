import AppKit
import KeyboardShortcuts
import SwiftUI

/// The helper of quick entry (R115): started at login, it answers the key while Lists is not running
/// and shows the same quick-entry window. It has no icon in the Dock, no menu bar item and no window.
@main
struct ListsHelperApp: App {
    @NSApplicationDelegateAdaptor(HelperDelegate.self) private var delegate

    init() {
        // The key is read by its library from the standard settings: those of Lists are put behind them.
        UserDefaults.standard.addSuite(named: LoginItems.appIdentifier)
    }

    var body: some Scene {
        // A scene there must be. This one is never opened; with it comes the Edit menu, from which
        // the fields of the card take ⌘V, ⌘C and ⌘Z.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {}
                CommandGroup(replacing: .appTermination) {}
            }
    }
}

final class HelperDelegate: NSObject, NSApplicationDelegate {
    private var holdsKey = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyboardShortcuts.onKeyUp(for: .quickEntry) {
            MainActor.assumeIsolated { HelperDelegate.present() }
        }
        MainActor.assumeIsolated { AppModel.shared.applyAppearance() }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard Self.isLists(note) else { return }
            MainActor.assumeIsolated { self?.followLists() }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard Self.isLists(note) else { return }
            MainActor.assumeIsolated { self?.followLists() }
        }
        MainActor.assumeIsolated { followLists() }
        #if DEBUG
        MainActor.assumeIsolated { DebugScript.runIfAsked() }
        #endif
    }

    /// The program whose runs the helper follows: Lists. A check names another one, so that the Lists
    /// of the person at the machine is left alone.
    private static let followed: String = {
        #if DEBUG
        if let other = ProcessInfo.processInfo.environment["LISTS_DEBUG_FOLLOW"] { return other }
        #endif
        return LoginItems.appIdentifier
    }()

    private static func isLists(_ note: Notification) -> Bool {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == followed
    }

    /// The window opens on what Lists holds now: the settings and the lists may have changed since the helper started.
    @MainActor
    static func present() {
        if QuickEntryPanel.shared.isVisible { return QuickEntryPanel.shared.close() }
        AppModel.shared.reloadSettings()
        AppModel.shared.reload()
        QuickEntryPanel.shared.present()
    }

    /// While Lists runs it answers the key itself; the helper holds the key the rest of the time.
    @MainActor
    func followLists() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.followed).contains { !$0.isTerminated }
        guard running == holdsKey else { return }
        holdsKey = !running
        if running {
            QuickEntryPanel.shared.close()
            KeyboardShortcuts.disable(.quickEntry)
            DistributedNotificationCenter.default().postNotificationName(LoginItems.keyReleased, object: nil, userInfo: nil, deliverImmediately: true)
        } else {
            KeyboardShortcuts.enable(.quickEntry)
        }
        AppModel.shared.store?.log(level: .info, source: "helper", message: running ? "Lists is running: the key is left to it" : "the key of quick entry is taken")
        #if DEBUG
        print("debug: helper key \(holdsKey ? "held" : "released")")
        #endif
    }
}
