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

    enum Item { case app, helper }

    enum State: Equatable { case off, on, needsApproval }

    static func state(_ status: SMAppService.Status) -> State {
        switch status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        // An item that was never turned on is "not found" to the system.
        default: .off
        }
    }

    static func state(_ item: Item) -> State {
        switch item {
        case .app: state(SMAppService.mainApp.status)
        case .helper: HelperAgent.state
        }
    }

    static func set(_ item: Item, on: Bool) throws {
        switch item {
        case .app: if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        case .helper: try HelperAgent.set(on: on)
        }
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

/// The helper as a launch agent of the user: a file in `~/Library/LaunchAgents` that names the
/// program inside Lists.app.
///
/// The system has a place of its own for a helper inside an app (`SMAppService.loginItem`), and it
/// starts one only from an app signed by a developer: in a build signed ad hoc the helper is killed
/// at the start ("Launch Constraint Violation"), while the system goes on saying it is on. A launch
/// agent is started whatever the signature is.
enum HelperAgent {
    struct Refusal: LocalizedError {
        let errorDescription: String?
    }

    /// A debug build has an agent of its own and does not take the place of the installed one.
    static let label: String = {
        #if DEBUG
        return LoginItems.helperIdentifier + ".debug"
        #else
        return LoginItems.helperIdentifier
        #endif
    }()

    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var program: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/ListsHelper.app/Contents/MacOS/ListsHelper")
    }

    private static var domain: String { "gui/\(getuid())" }
    private static var service: String { "\(domain)/\(label)" }

    @discardableResult
    private static func launchctl(_ arguments: String...) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Not `waitUntilExit`: it runs the event loop while it waits. The state of the helper is read while
        // `AppModel.shared` is still being built, and a task of the main actor that ran inside that wait
        // and asked for `AppModel.shared` stopped the app at launch.
        while process.isRunning { usleep(1000) }
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static var loaded: Bool { launchctl("print", service).status == 0 }

    /// On: the file is there and the system holds the agent. The file without the agent is an agent
    /// the system was told not to run, in System Settings → General → Login Items.
    static var state: LoginItems.State {
        guard FileManager.default.fileExists(atPath: file.path) else { return .off }
        return loaded ? .on : .needsApproval
    }

    private static func unload() {
        guard loaded else { return }
        launchctl("bootout", service)
        // The agent leaves a moment after the answer; it cannot be handed over again before that.
        for _ in 0..<40 {
            if !loaded { break }
            usleep(50_000)
        }
    }

    static func set(on: Bool) throws {
        let fm = FileManager.default
        unload()
        guard on else {
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            return
        }
        var agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [program.path],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            // Login Items of System Settings show the agent under the name of Lists.
            "AssociatedBundleIdentifiers": [LoginItems.appIdentifier],
        ]
        #if DEBUG
        // A check keeps the helper on the throwaway folder it runs Lists on.
        let kept = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("LISTS_DEBUG_") && $0.key != "LISTS_DEBUG_SCRIPT" }
        if !kept.isEmpty { agent["EnvironmentVariables"] = kept }
        #endif
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0).write(to: file, options: .atomic)
        let started = launchctl("bootstrap", domain, file.path)
        if started.status != 0 { throw Refusal(errorDescription: started.output) }
    }

    /// Called when Lists starts. The helper is started again: it may be the one of a version that has
    /// since been replaced, and an old core must not write into a newer data folder. A file that
    /// names Lists at another place, after the app was moved, is written again.
    static func renew() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let named = (NSDictionary(contentsOf: file)?["ProgramArguments"] as? [String])?.first
        // Not on the thread of the launch: the system stops the helper at once, but keeps ten seconds between two
        // starts of one agent, and the command waits for the start. A launch that followed another one within
        // those seconds waited with it (#247).
        let moved = named != program.path
        DispatchQueue.global(qos: .userInitiated).async {
            if moved {
                try? set(on: true)
            } else {
                launchctl("kickstart", "-k", service)
            }
        }
    }
}
