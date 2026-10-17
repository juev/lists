import AppKit
import EventKit
import Foundation
import Observation

/// R72: the name of the list in the colour of the list, then the project: "List – Project".
struct RowOrigin: Equatable {
    let list: String?
    let color: String?
    let project: String?

    var label: String { [list, project].compactMap { $0 }.joined(separator: " – ") }
}

struct TaskSection: Identifiable {
    let id: String
    let title: String?
    var tasks: [TaskItem]
}

/// Everything the windows show, read from the core after each change.
/// Core calls are local SQLite queries and run on the main thread; only sync,
/// which talks to the network, runs in the background.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let store: Store?
    var startupError: String?

    var lists: [TaskList] = []
    var tags: [TagCount] = []
    var projects: [TaskItem] = []
    var filters: [SavedFilter] = []
    var counts = Counts(inbox: 0, today: 0, overdue: 0, upcoming: 0, trash: 0, all: 0, completed: 0, wontDo: 0)

    var scope: Scope = .today { didSet { if scope != oldValue { expanded.removeAll(); subtasksShown.removeAll(); draft = nil; selection = nil; reload() } } }
    var search = "" { didSet { if search != oldValue { reload() } } }
    /// Search is an icon until it is asked for (R80); each request, the first one and ⌘F after it, gives the field the keyboard.
    var searchRequests = 0
    var searchOpen = false
    var sections: [TaskSection] = []
    /// Minutes a completed task stays in its view; shared by all devices (R68).
    private(set) var keepDone: KeepDone = .seconds(seconds: 5)
    var children: [String: [TaskItem]] = [:]
    /// R22: the subtasks a search found a task by, shown as lines under its row.
    var found: [String: [TaskItem]] = [:]
    var expanded: Set<String> = []
    /// Expanded tasks whose subtasks are on show; they stay folded until asked for.
    var subtasksShown: Set<String> = []
    /// Moving to another row closes the open card: one card is open at a time.
    var selection: String? {
        didSet {
            // R117: a selection made the plain way is of one row, and a range of Shift starts from it.
            if !keepsPicked {
                if !picked.isEmpty { picked = [] }
                anchor = selection
            }
            if titleFocus != selection { titleFocus = nil }
            // The title of a subtask is saved when the selection leaves its line, as a card saves on closing (R38).
            if let renaming, renaming != selection { finishRenaming(renaming, save: true) }
            if let selection, selection != oldValue { closeCards(except: selection) }
        }
    }
    /// R117: the rows selected together; empty while one row or none is selected. `selection` is the one
    /// of them the keys go on from.
    private(set) var picked: Set<String> = []
    /// R117: the row a range of Shift starts from.
    @ObservationIgnored private var anchor: String?
    @ObservationIgnored private var keepsPicked = false
    /// The card of a task that does not exist yet, while it is open (⌘N).
    var draft: TaskDraft?
    /// The task whose title takes the keyboard as soon as its card is on screen.
    var titleFocus: String?
    /// The subtask whose title is being edited in its line, and the text typed so far (R38).
    private(set) var renaming: String?
    var renamingTitle = ""
    /// Counts the cards closed from the keyboard: each time the list takes the keyboard back.
    var listFocusRequests = 0
    // Sheets of the sidebar; here so that the menu bar can open them too.
    var creatingList = false
    var creatingFilter = false
    var creatingProject = false

    var syncStatus = SyncStatus(configured: false, pending: 0, attachmentsWaiting: 0, lastOk: nil, lastError: nil)
    /// Moves when attachment content has arrived: an open card reads its files again (R76).
    var attachmentsArrived = 0
    var syncing = false
    /// Text size factor and font design chosen in Settings.
    /// A launch argument (`-textScale 1.5`) arrives as a string.
    var textScale: Double = Storage.defaults.object(forKey: AppFont.scaleKey)
        .flatMap({ ($0 as? Double) ?? ($0 as? String).flatMap(Double.init) }) ?? 1.0 {
        didSet { Storage.defaults.set(textScale, forKey: AppFont.scaleKey) }
    }
    var fontDesign: String = Storage.defaults.string(forKey: AppFont.designKey) ?? "default" {
        didSet { Storage.defaults.set(fontDesign, forKey: AppFont.designKey) }
    }
    /// R122: how far apart the task rows stand, one of `RowSpacing.choices`; belongs to this Mac.
    var rowSpacing: String = RowSpacing.from(Storage.defaults.string(forKey: RowSpacing.key)) {
        didSet { Storage.defaults.set(rowSpacing, forKey: RowSpacing.key) }
    }
    /// "system", "light" or "dark" (R61); belongs to this Mac.
    var appearance: String = Storage.defaults.string(forKey: "appearance") ?? "system" {
        didSet {
            Storage.defaults.set(appearance, forKey: "appearance")
            applyAppearance()
        }
    }
    /// What the Dock icon counts (R103): "today", "overdue" or "none"; belongs to this Mac.
    var dockCount: String = Storage.defaults.string(forKey: "dockCount") ?? "today" {
        didSet {
            Storage.defaults.set(dockCount, forKey: "dockCount")
            applyDockCount()
        }
    }
    /// R116: whether Lists has its item in the menu bar; belongs to this Mac.
    var menuBarItem: Bool = Storage.defaults.object(forKey: "menuBarItem") as? Bool ?? true {
        didSet {
            Storage.defaults.set(menuBarItem, forKey: "menuBarItem")
            // Without the item nothing on screen would open Lists: the Dock icon comes back.
            if !menuBarItem && hiddenFromDock { hiddenFromDock = false }
            applyDockIcon()
        }
    }
    /// R116: whether Lists is taken out of the Dock; only while it has its item in the menu bar.
    var hiddenFromDock: Bool = Storage.defaults.bool(forKey: "hiddenFromDock") {
        didSet {
            // Asked for without the item in the menu bar, it is not taken.
            if hiddenFromDock && !menuBarItem { return hiddenFromDock = false }
            Storage.defaults.set(hiddenFromDock, forKey: "hiddenFromDock")
            guard hiddenFromDock != oldValue else { return }
            // The change of the policy takes the app out of the front: the window where it was made stays there.
            let active = NSApp?.isActive == true
            applyDockIcon()
            if active { NSApp?.activate(ignoringOtherApps: true) }
        }
    }
    /// R116: whether Lists opened at login shows its window.
    var windowAtLogin: Bool = Storage.defaults.object(forKey: "windowAtLogin") as? Bool ?? true {
        didSet { Storage.defaults.set(windowAtLogin, forKey: "windowAtLogin") }
    }

    /// R116: out of the Dock only with the item in the menu bar, whatever was stored.
    static func outOfDock(asked: Bool, menuBarItem: Bool) -> Bool { asked && menuBarItem }
    var outOfDock: Bool { Self.outOfDock(asked: hiddenFromDock, menuBarItem: menuBarItem) }

    /// The model loads before there is an application: the launch applies the choice once more.
    func applyDockIcon() {
        if LoginItems.isHelper { return }
        NSApp?.setActivationPolicy(outOfDock ? .accessory : .regular)
        // An icon that comes back carries the count again (R103).
        applyDockCount()
    }

    /// The helper of quick entry (R115) keeps no settings of its own: before it shows the window it
    /// reads again what Lists holds, since the settings may have changed while it was running.
    func reloadSettings() {
        let defaults = Storage.defaults
        // What is assigned below is written back: it must be what Lists wrote last, not what this program remembers.
        defaults.synchronize()
        textScale = defaults.object(forKey: AppFont.scaleKey).flatMap { ($0 as? Double) ?? ($0 as? String).flatMap(Double.init) } ?? 1.0
        fontDesign = defaults.string(forKey: AppFont.designKey) ?? "default"
        appearance = defaults.string(forKey: "appearance") ?? "system"
        returnAddsLine = defaults.object(forKey: "returnAddsLine") == nil || defaults.bool(forKey: "returnAddsLine")
        parseQuickText = defaults.object(forKey: "parseQuickText") == nil || defaults.bool(forKey: "parseQuickText")
        clipboardNotes = defaults.object(forKey: "clipboardNotes") == nil || defaults.bool(forKey: "clipboardNotes")
    }

    /// What the system says about the two login items (R115), and the text of a refusal to change one.
    private(set) var opensAtLogin = LoginItems.State.off
    private(set) var helperAtLogin = LoginItems.State.off
    var loginItemRefusal: [LoginItems.Item: String] = [:]

    func reloadLoginItems() {
        opensAtLogin = LoginItems.state(.app)
        helperAtLogin = LoginItems.state(.helper)
    }

    func setLoginItem(_ item: LoginItems.Item, on: Bool) {
        do {
            try LoginItems.set(item, on: on)
            loginItemRefusal[item] = nil
        } catch {
            loginItemRefusal[item] = error.localizedDescription
            store?.log(level: .error, source: "login", message: "\(item == .app ? "Lists" : "the helper") at login \(on ? "on" : "off") refused: \(error.localizedDescription)")
        }
        reloadLoginItems()
    }

    var alert: String?
    /// Tasks whose attachments are being saved into a folder (R91); the rows of files still to arrive show it.
    var savingAttachments: Set<String> = []
    /// False while `alert` carries a report rather than a failure.
    var alertIsError = true

    // Notification settings of this Mac; not synced.
    var notifyEnabled: Bool = Storage.defaults.object(forKey: "notifyEnabled") as? Bool ?? true { didSet { saveNotify() } }
    /// Minutes before a timed due date, one notification for each; empty turns these reminders off.
    var notifyLeads: Set<Int> = AppModel.storedLeads() { didSet { saveNotify() } }
    /// `HH:MM`, empty for off.
    var notifyAllDay: String = Storage.defaults.string(forKey: "notifyAllDay") ?? "09:00" { didSet { saveNotify() } }
    var notifySummary: String = Storage.defaults.string(forKey: "notifySummary") ?? "" { didSet { saveNotify() } }
    var notifySound: Bool = Storage.defaults.object(forKey: "notifySound") as? Bool ?? true { didSet { saveNotify() } }
    /// A system alert sound by its name, empty for the standard sound of notifications (R36).
    var notifySoundName: String = Storage.defaults.string(forKey: "notifySoundName") ?? "" { didSet { saveNotify() } }
    /// What a notification plays: nil for silence.
    var notifySoundChoice: String? { notifySound ? notifySoundName : nil }

    var notifySettings: NotifySettings {
        NotifySettings(
            enabled: notifyEnabled,
            leadMinutes: notifyLeads.sorted().map(UInt32.init),
            allDayAt: notifyAllDay.isEmpty ? nil : notifyAllDay,
            summaryAt: notifySummary.isEmpty ? nil : notifySummary)
    }

    /// Whether the system lets Lists show notifications; Settings show a line when it does not (R111).
    private(set) var notificationAccess = Reminders.Access.unasked

    /// Reads what the system holds. `refusal` is the error of a request that was just refused.
    func reloadNotificationAccess(refusal: String? = nil) {
        // The notifications belong to Lists; the helper asks the system nothing (R115).
        if LoginItems.isHelper { return }
        Task { noteNotificationAccess(await Reminders.shared.access(), refusal: refusal) }
    }

    /// Takes the answer of the system: writes a refusal to the log and hands the plan over again when the refusal ends.
    func noteNotificationAccess(_ access: Reminders.Access, refusal: String? = nil) {
        guard access != notificationAccess else { return }
        let was = notificationAccess
        notificationAccess = access
        switch access {
        case .denied:
            store?.log(level: .error, source: "notify", message: "the system does not allow notifications\(refusal.map { ": \($0)" } ?? "")")
        case .granted where was == .denied:
            store?.log(level: .info, source: "notify", message: "the system allows notifications")
            Reminders.shared.forget()
            Reminders.shared.refresh(store, settings: notifySettings, sound: notifySoundChoice)
        default:
            break
        }
    }

    private func saveNotify() {
        let defaults = Storage.defaults
        defaults.set(notifyEnabled, forKey: "notifyEnabled")
        defaults.set(notifyLeads.sorted(), forKey: "notifyLeads")
        defaults.set(notifyAllDay, forKey: "notifyAllDay")
        defaults.set(notifySummary, forKey: "notifySummary")
        defaults.set(notifySound, forKey: "notifySound")
        defaults.set(notifySoundName, forKey: "notifySoundName")
        Reminders.shared.refresh(store, settings: notifySettings, sound: notifySoundChoice)
    }

    /// Before several lead times were allowed there was one, kept under `notifyLead`.
    private static func storedLeads() -> Set<Int> {
        let defaults = Storage.defaults
        let stored = defaults.array(forKey: "notifyLeads") as? [Int]
        let legacy = defaults.object(forKey: "notifyLead") as? Int
        let moved = defaults.bool(forKey: "notifyLeadsAtTime")
        let leads = leads(stored: stored, legacy: legacy, moved: moved)
        if !moved {
            // Once: the choice is written only where the update changed it, so a Mac that never chose keeps following the default.
            defaults.set(true, forKey: "notifyLeadsAtTime")
            if stored != nil || legacy != nil { defaults.set(leads.sorted(), forKey: "notifyLeads") }
        }
        return leads
    }

    /// R36: without a choice the reminder comes at the time the task is due. The default used to be
    /// 15 minutes before, and every save of these settings wrote it down, so a stored 15 alone does not
    /// tell a choice from the old default: the update turns it into "at the time" once (`moved` is false until then).
    /// `legacy` is the single value kept before several were allowed, negative for off.
    static func leads(stored: [Int]?, legacy: Int?, moved: Bool) -> Set<Int> {
        guard let leads = stored.map(Set.init) ?? legacy.map({ $0 < 0 ? [] : [$0] }) else { return [0] }
        return !moved && leads == [15] ? [0] : leads
    }

    /// Where a new task goes when the view does not say: `inbox`, `last` or a list id (R40); synced.
    private(set) var newTaskList = "inbox"
    /// Inbox has no row while it holds no open tasks (R121); synced.
    private(set) var inboxHidden = false

    func setNewTaskList(_ choice: String) {
        perform { try $0.setNewTaskList(choice: choice) }
    }

    // Editing habits of this Mac; not synced.
    /// Return in the notes starts a new line (Esc finishes); otherwise it finishes editing and ⌥Return starts a line.
    var returnAddsLine: Bool = Storage.defaults.object(forKey: "returnAddsLine") == nil || Storage.defaults.bool(forKey: "returnAddsLine") {
        didSet { Storage.defaults.set(returnAddsLine, forKey: "returnAddsLine") }
    }

    /// When each built-in view has a row in the sidebar of this Mac (R93); not synced.
    var sidebarShow: [String: SidebarShow] = AppModel.storedSidebarShow() {
        didSet {
            Storage.defaults.set(sidebarShow.mapValues(\.rawValue), forKey: "sidebarShow")
            leaveHiddenView()
        }
    }

    private static func storedSidebarShow() -> [String: SidebarShow] {
        let defaults = Storage.defaults
        // The setting this one replaced (R47): a Mac that had Completed switched off keeps it off,
        // until the two views are given a choice of their own. Only the views that were chosen are stored.
        let old = defaults.object(forKey: "showCompletedView") != nil && !defaults.bool(forKey: "showCompletedView")
        var show: [String: SidebarShow] = old ? ["completed": .never, "wontDo": .never] : [:]
        let stored = (defaults.dictionary(forKey: "sidebarShow") as? [String: String]) ?? [:]
        show.merge(stored.compactMapValues(SidebarShow.init(rawValue:))) { _, chosen in chosen }
        return show
    }

    func sidebarShow(_ scope: Scope) -> SidebarShow {
        guard let name = scope.builtinName else { return .always }
        return sidebarShow[name] ?? SidebarShow.initial(scope)
    }

    func setSidebarShow(_ scope: Scope, _ show: SidebarShow) {
        guard let name = scope.builtinName else { return }
        sidebarShow[name] = show
    }

    /// Whether the view has something to show, as the counts know it.
    private func holds(_ scope: Scope) -> Bool {
        switch scope {
        case .inbox: counts.inbox > 0
        case .today: counts.today > 0
        case .upcoming: counts.upcoming > 0
        case .all: counts.all > 0
        case .completed: counts.completed > 0
        case .wontDo: counts.wontDo > 0
        case .trash: counts.trash > 0
        default: true
        }
    }

    /// Whether the sidebar and the Go menu offer the view (R93). Inbox has a row unless it is
    /// hidden and holds no open tasks (R121).
    func showsInSidebar(_ scope: Scope) -> Bool {
        if scope == .inbox { return !inboxHidden || holds(.inbox) }
        switch sidebarShow(scope) {
        case .always: return true
        case .filled: return holds(scope)
        case .never: return false
        }
    }

    /// The built-in views that have a row in the sidebar, in its order.
    var shownBuiltins: [Scope] { Scope.builtins.filter(showsInSidebar) }

    /// The view on screen lost its row: the app goes to Inbox (R93).
    private func leaveHiddenView() {
        if scope != .inbox, scope.builtinName != nil, !showsInSidebar(scope) { scope = .inbox }
    }

    // Calendar events in Today (R78); settings of this Mac, not synced.
    /// Off until asked for: the system is asked for the calendars when this is turned on, not before.
    var showCalendarEvents: Bool = Storage.defaults.bool(forKey: "calendarEvents") {
        didSet {
            guard showCalendarEvents != oldValue else { return }
            Storage.defaults.set(showCalendarEvents, forKey: "calendarEvents")
            if showCalendarEvents, SystemCalendars.shared.access == .unasked {
                SystemCalendars.shared.ask { [weak self] in self?.reloadEvents() }
            }
            reloadEvents()
        }
    }
    /// The calendars whose mark was taken off; a calendar that appears later is shown.
    var hiddenCalendars: Set<String> = Set(Storage.defaults.stringArray(forKey: "calendarEventsHidden") ?? []) {
        didSet {
            Storage.defaults.set(hiddenCalendars.sorted(), forKey: "calendarEventsHidden")
            reloadEvents()
        }
    }
    var dayEvents: [DayEvent] = []
    private(set) var eventCalendars: [EventCalendar] = []
    private(set) var calendarAccess = SystemCalendars.Access.unasked
    /// The block stands in Today only, and only while there is an event to show.
    var eventsShown: Bool { effectiveScope == .today && !dayEvents.isEmpty }

    func reloadEvents() {
        let calendars = SystemCalendars.shared
        calendarAccess = calendars.access
        guard showCalendarEvents, calendarAccess == .granted else {
            dayEvents = []
            eventCalendars = []
            return
        }
        eventCalendars = calendars.calendars()
        dayEvents = calendars.today(hidden: hiddenCalendars)
    }

    /// Whether dates, priority, tags and a list are picked out of the typed title.
    var parseQuickText: Bool = Storage.defaults.object(forKey: "parseQuickText") == nil || Storage.defaults.bool(forKey: "parseQuickText") {
        didSet { Storage.defaults.set(parseQuickText, forKey: "parseQuickText") }
    }
    /// Whether quick entry starts the note with what is on the clipboard (R58).
    var clipboardNotes: Bool = Storage.defaults.object(forKey: "clipboardNotes") == nil || Storage.defaults.bool(forKey: "clipboardNotes") {
        didSet { Storage.defaults.set(clipboardNotes, forKey: "clipboardNotes") }
    }

    /// The list for a task entered where no list is implied: quick entry, Today, a tag.
    /// Gives every window of the app the chosen look; `nil` follows the system.
    func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// The number on the Dock icon (R103); none when there is nothing to count.
    var dockBadge: String? {
        let count: UInt32 = switch dockCount {
        case "today": counts.today
        case "overdue": counts.overdue
        default: 0
        }
        return count > 0 ? String(count) : nil
    }

    /// The model loads before there is an application: the launch applies the number once more.
    func applyDockCount() {
        NSApp?.dockTile.badgeLabel = dockBadge
    }

    var defaultListId: String {
        (try? store?.defaultListId(lastUsed: Storage.defaults.string(forKey: "lastUsedList"))) ?? "inbox"
    }

    /// The lists Inbox can be hidden in favour of (R121).
    var listsForHiddenInbox: [TaskList] { lists.filter { !$0.archived && $0.id != "inbox" } }

    /// R121: hides Inbox, moving its open tasks to the list when asked; one undo takes it all back.
    func hideInbox(movingTo listId: String, moveTasks: Bool) {
        guard let hiding = perform({ try $0.hideInbox(listId: listId, moveTasks: moveTasks) }) else { return }
        noteUsedList(listId)
        if scope == .inbox { scope = .list(id: listId) }
        undoManager?.registerUndo(withTarget: self) { model in
            model.perform { try $0.undoHideInbox(hiding: hiding) }
        }
        undoManager?.setActionName(L("Hide Inbox"))
    }

    func showInbox() {
        perform { try $0.showInbox() }
    }

    func noteUsedList(_ id: String) {
        Storage.defaults.set(id, forKey: "lastUsedList")
    }

    @ObservationIgnored private var syncDebounce: DispatchWorkItem?
    @ObservationIgnored private var movingAttachments = false
    @ObservationIgnored private var timer: Timer?
    /// Fires when the first of the kept completed tasks is due to leave its view (R68).
    @ObservationIgnored private var keptTimer: Timer?
    @ObservationIgnored private let folderWatcher = FolderWatcher()
    @ObservationIgnored weak var undoManager: UndoManager?

    private init() {
        #if DEBUG
        // The check of the launch (`scripts/check-launch.sh`, #240). A task of the main actor that asks for the model
        // waits in the queue while the model is built. It runs afterwards, unless something on the way runs the event
        // loop: then it runs inside the building, asks for a model that is not there yet, and the system stops the
        // app, which is how 0.3.1 stopped at launch (#239).
        if ProcessInfo.processInfo.environment["LISTS_DEBUG_LAUNCH_PROBE"] != nil {
            Task { @MainActor in
                _ = AppModel.shared
                print("debug: launch probe ran after the model was built")
            }
        }
        #endif
        // R115: the helper left from the version before an update is replaced before anything else. The rest of
        // the launch can wait for a long time, for the answer about the keychain for one, and all that while
        // the old helper would go on writing into the data folder with the old core.
        if !LoginItems.isHelper { HelperAgent.renew() }
        #if DEBUG
        // A check holds the launch here for that many seconds, in place of a wait it cannot stage.
        if let hold = ProcessInfo.processInfo.environment["LISTS_DEBUG_HOLD_START"].flatMap(UInt32.init) { sleep(hold) }
        #endif
        do {
            let opened = try Storage.openStore()
            store = opened
            // R102: a setting that is not read leaves its secret out of the core, and sync or push fails later.
            func read<T>(_ source: String, _ what: String, _ value: () throws -> T) -> T? {
                do { return try value() } catch {
                    opened.log(level: .error, source: source, message: "the \(what) were not read at launch: \(logged(error))")
                    return nil
                }
            }
            // The helper does not sync (R115): the passwords stay with Lists.
            switch LoginItems.isHelper ? nil : read("sync", "sync settings", opened.syncConfig) {
            case .webDav(let url, let user)?, .calDav(let url, let user)?:
                opened.setSyncPassword(password: Keychain.load(account: Keychain.account(url: url, user: user)))
            default: break
            }
            if !LoginItems.isHelper, let server = read("push", "push settings", opened.pushServer) ?? nil {
                opened.setPushToken(token: Keychain.load(account: Keychain.pushAccount(server: server)))
            }
            // R40: the choice this Mac kept before it synced goes to the shared settings once.
            if !LoginItems.isHelper, let kept = Storage.defaults.string(forKey: "newTaskList") {
                if read("app", "default list for new tasks", { try opened.adoptNewTaskList(choice: kept) }) != nil {
                    Storage.defaults.removeObject(forKey: "newTaskList")
                }
            }
            // R102: where a log of events begins for this run.
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let system = ProcessInfo.processInfo.operatingSystemVersion
            store?.log(level: .info, source: LoginItems.isHelper ? "helper" : "app", message: "started \(version) on macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")
        } catch {
            store = nil
            startupError = describe(error)
        }
        reload()
        // The helper only writes tasks: it does not sync, back up, notify or read the calendar (R115).
        if LoginItems.isHelper { return }
        reloadNotificationAccess()
        reloadLoginItems()
        DistributedNotificationCenter.default().addObserver(
            forName: Storage.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(); self?.scheduleSync() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(); self?.reloadEvents(); self?.reloadNotificationAccess(); self?.reloadLoginItems(); self?.syncNow() }
        }
        // R78: the block follows the calendars of the system and the change of the day.
        for name in [Notification.Name.EKEventStoreChanged, .NSCalendarDayChanged] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadEvents() }
            }
        }
        // R103: what is due today and what is overdue change with the day.
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reloadEvents()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow(); self?.backupIfDue() }
        }
        backupIfDue()
        watchSyncFolder()
        listenForNudges()
    }

    /// Another device that uploaded a change asks this one to sync. The call
    /// blocks on a thread of its own until that happens, and paces itself
    /// while no push server is set or it cannot be reached.
    private func listenForNudges() {
        guard let store else { return }
        Thread.detachNewThread { [weak self] in
            while true {
                if store.waitForNudge() {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncNow() } }
                }
            }
        }
    }

    // MARK: Reading

    var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    var effectiveScope: Scope { isSearching ? .search(text: search) : scope }

    var allTasks: [TaskItem] { sections.flatMap(\.tasks) }

    /// The sections as they are drawn. A view that mixes lists has a task of a project as a row of
    /// its own; while it is on show inside the open card of the project that row is left out.
    /// A subtask is never a row of its own (R10).
    var visibleSections: [TaskSection] {
        let nested = Set(allTasks.filter { $0.isProject && expanded.contains($0.id) }.flatMap { children[$0.id] ?? [] }.map(\.id))
        guard !nested.isEmpty else { return sections }
        return sections.compactMap { section in
            var section = section
            section.tasks.removeAll { nested.contains($0.id) }
            return section.tasks.isEmpty ? nil : section
        }
    }

    func list(_ id: String) -> TaskList? { lists.first { $0.id == id } }

    /// R72: whether the view holds tasks of several lists, so that a row has to say where its task lives.
    var mixesLists: Bool {
        switch effectiveScope {
        case .today, .upcoming, .all, .tag, .search, .completed, .wontDo, .trash, .filter: return true
        default: return false
        }
    }

    /// R72: what a row says about where its task lives in a view that mixes lists: the list, the Inbox
    /// among them, and the project of a task of a project.
    func origin(of task: TaskItem) -> RowOrigin? {
        let list = list(task.listId)
        guard list != nil || task.parentTitle != nil else { return nil }
        return RowOrigin(list: list.map(listName), color: list?.color, project: task.parentTitle)
    }

    func listName(_ list: TaskList) -> String { list.id == "inbox" ? L("Inbox") : list.name }

    /// Whether the heading of the group of the row already names the day of the due date of its task (R72).
    func dayInHeading(_ task: TaskItem) -> Bool {
        switch effectiveScope {
        case .today: return task.effectiveDue.map { Moment.day($0) == Moment.today() } ?? false
        case .upcoming: return true
        default: return false
        }
    }

    var scopeTitle: String {
        switch effectiveScope {
        case .inbox: return L("Inbox")
        case .today: return L("Today")
        case .upcoming: return L("Upcoming")
        case .all: return L("All")
        case .completed: return L("Completed")
        case .wontDo: return L("Won't do")
        case .trash: return L("Trash")
        case .list(let id): return list(id).map(listName) ?? L("List")
        case .tag(let name): return "#\(name)"
        case .search: return L("Search")
        case .project(let id): return projects.first { $0.id == id }?.title ?? L("Project")
        case .filter(let id): return filters.first { $0.id == id }?.name ?? L("Filter")
        }
    }

    /// The list a task created in the current view goes to.
    var targetListId: String {
        switch scope {
        case .inbox: return "inbox"
        case .list(let id): return id
        default: return defaultListId
        }
    }

    /// Creates an empty project and opens its view (R127). It goes to the list on screen,
    /// to the list of the open project, or where the view has no list, to the default one (R40).
    func createProject(title: String) {
        var listId = targetListId
        if case .project(let id) = scope, let project = projects.first(where: { $0.id == id }) { listId = project.listId }
        if let project = perform({ try $0.createProject(title: title, listId: listId) }) { scope = .project(id: project.id) }
    }

    /// Manual reordering makes sense only where the order shown is the stored one.
    var canReorder: Bool {
        guard !isSearching else { return false }
        switch scope {
        case .inbox: return list("inbox")?.sort == .manual
        case .list(let id): return list(id)?.sort == .manual
        default: return false
        }
    }

    func setKeepDone(_ keep: KeepDone) {
        perform { try $0.setKeepDone(keep: keep) }
    }

    func reload() {
        guard let store else { return }
        // After the counts are new: a view that holds nothing any more may have lost its row.
        defer { leaveHiddenView() }
        do {
            lists = try store.lists()
            tags = try store.tags()
            counts = try store.counts()
            applyDockCount()
            syncStatus = try store.syncStatus()
            keepDone = try store.keepDone()
            newTaskList = try store.newTaskList()
            inboxHidden = try store.inboxHidden()
            // Kept rows leave by the clock, not by a change: look again when the first one is due.
            keptTimer?.invalidate()
            keptTimer = try store.secondsUntilKeptLeaves().map { seconds in
                Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reload() }
                }
            }
            if case .list(let id) = scope, list(id) == nil { scope = .inbox }
            if case .tag(let name) = scope, !tags.contains(where: { $0.name == name }) { scope = .inbox }
            projects = try store.projects()
            filters = try store.filters()
            if case .project(let id) = scope, !projects.contains(where: { $0.id == id }) { scope = .inbox }
            if case .filter(let id) = scope, !filters.contains(where: { $0.id == id }) { scope = .inbox }
            sections = group(try store.tasks(view: effectiveScope))
            var loaded: [String: [TaskItem]] = [:]
            for id in expanded {
                loaded[id] = try store.subtasks(parentId: id)
            }
            children = loaded
            var lines: [String: [TaskItem]] = [:]
            if isSearching {
                for task in allTasks where task.subtasksTotal > 0 {
                    let subtasks = try store.foundSubtasks(parentId: task.id, text: search)
                    if !subtasks.isEmpty { lines[task.id] = subtasks }
                }
            }
            found = lines
            prunePicked()
            if !LoginItems.isHelper { Reminders.shared.refresh(store, settings: notifySettings, sound: notifySoundChoice) }
        } catch {
            alert = describe(error)
        }
    }

    private func group(_ tasks: [TaskItem]) -> [TaskSection] {
        switch effectiveScope {
        case .today:
            let today = Moment.today()
            // R84: overdue is a due date that has passed. A start date in the past only makes the task available.
            // R125: a task of a project goes by the project's due date when it has none of its own.
            let isOverdue: (TaskItem) -> Bool = { task in task.effectiveDue.map { Moment.day($0) < today } ?? false }
            let overdue = tasks.filter(isOverdue)
            let rest = tasks.filter { !isOverdue($0) }
            if overdue.isEmpty { return [TaskSection(id: "today", title: nil, tasks: rest)] }
            return [
                TaskSection(id: "overdue", title: L("Overdue"), tasks: overdue),
                TaskSection(id: "today", title: L("Today"), tasks: rest),
            ].filter { !$0.tasks.isEmpty }
        case .upcoming:
            return sectioned(tasks, key: { Moment.day($0.effectiveDue ?? $0.effectiveStart ?? "") }, title: Moment.heading)
        case .all:
            return sectioned(tasks, key: \.listId, title: { id in self.list(id).map(self.listName) ?? "" })
        case .completed, .wontDo:
            return sectioned(tasks, key: { Moment.day($0.done ?? "") }, title: { Moment.label($0) })
        default:
            return [TaskSection(id: "all", title: nil, tasks: tasks)]
        }
    }

    /// Splits an already ordered list into runs with the same key.
    private func sectioned(_ tasks: [TaskItem], key: (TaskItem) -> String, title: (String) -> String) -> [TaskSection] {
        var out: [TaskSection] = []
        for task in tasks {
            let k = key(task)
            if out.last?.id == k {
                out[out.count - 1].tasks.append(task)
            } else {
                out.append(TaskSection(id: k, title: title(k), tasks: [task]))
            }
        }
        return out
    }

    // MARK: Writing

    /// Runs a change, then refreshes what is on screen and queues a sync. What the change puts into
    /// the history of undo of the core is one step of ⌘Z, under `name` in the Edit menu (R131).
    @discardableResult
    func perform<T>(named name: String? = nil, _ change: (Store) throws -> T) -> T? {
        guard let store else { return nil }
        let revision = store.undoRevision()
        store.beginGroup()
        let result = Result { try change(store) }
        store.endGroup()
        if store.undoRevision() != revision {
            undoManager?.registerUndo(withTarget: self) { model in
                model.perform { try $0.undo() }
            }
            undoManager?.setActionName(name ?? L("Change Tasks"))
        }
        reload()
        switch result {
        case .success(let value):
            scheduleSync()
            return value
        case .failure(let error):
            alertIsError = true
            alert = describe(error)
            return nil
        }
    }

    @discardableResult
    func add(_ text: String, parent: String? = nil) -> TaskItem? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        return perform { store in
            if let parent {
                return try store.createTask(new: NewTask(title: line, parentId: parent))
            }
            if case .project(let id) = scope {
                return try store.quickAddUnder(text: line, parentId: id, first: true)
            }
            let task = try store.quickAdd(text: line, listId: targetListId, first: true)
            noteUsedList(task.listId)
            return task
        }
    }

    /// Opens the card of a new task. The view gives it its list or its parent
    /// and nothing else (R75).
    func startDraft() {
        search = ""
        searchOpen = false
        switch scope {
        case .completed, .wontDo, .trash: scope = .inbox
        default: break
        }
        var new = TaskDraft(listId: targetListId)
        // R130: the task selected now is the one the new task goes under; the card of the main window stands there.
        new.after = selectedTask?.id
        if case .project(let id) = scope {
            new.parentId = id
            // R129: the card shows the project; a list chosen there instead starts from the project's list.
            new.listId = projects.first { $0.id == id }?.listId ?? new.listId
        }
        expanded.removeAll()
        draft = new
    }

    /// What the title of a draft says, when titles are parsed.
    private func typed(_ draft: TaskDraft) -> QuickParse? {
        parseQuickText && !draft.isBlank ? store?.parseQuick(text: draft.title) : nil
    }

    /// The list whose defaults a draft is to get (R2); a subtask gets none.
    private func defaults(_ draft: TaskDraft) -> TaskList? {
        draft.parentId == nil ? list(draft.listId) : nil
    }

    /// The due date next to the icon of a new task (R75): the chosen one, or
    /// the one the list is going to give. The list gives its date only to a
    /// task without a start date, and a date in the title wins over it (R41).
    func shownDue(_ draft: TaskDraft) -> String? {
        if let due = draft.due { return due }
        guard !draft.dueRemoved, draft.start == nil, defaults(draft)?.defaultDueToday == true else { return nil }
        return typed(draft)?.due ?? Moment.today()
    }

    /// The priority next to the icon of a new task (R75), by the same rule.
    func shownPriority(_ draft: TaskDraft) -> Priority {
        if draft.priorityChosen { return draft.priority }
        guard let preset = defaults(draft)?.defaultPriority, preset != .none else { return .none }
        if let typed = typed(draft)?.priority, typed != .none { return typed }
        return preset
    }

    /// Closes the card of a new task the way Esc does: a task with a title is created, an empty card is dropped.
    func finishDraft() {
        guard let open = draft else { return }
        if open.isBlank {
            open.files.forEach(IncomingFiles.discard)
        } else {
            save(open)
        }
        draft = nil
    }

    /// Creates the task of a draft. What the fields say wins over what the
    /// title says, and the title wins over the defaults of the list.
    @discardableResult
    func save(_ draft: TaskDraft) -> TaskItem? {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let parse = parseQuickText
        // R37: Esc keeps the task of the card, so ⌘Z is the way to take a new task back: it goes to the trash.
        let task: TaskItem? = perform(named: L("New Task")) { store in
            let created: TaskItem
            // R130: a new task goes first in its list, or right under the task that was selected when the card opened.
            let after = draft.after
            switch (draft.parentId, parse) {
            case (let parent?, true): created = try store.quickAddUnder(text: title, parentId: parent, first: true, after: after)
            case (let parent?, false): created = try store.createTask(new: NewTask(title: title, parentId: parent, first: true, after: after))
            case (nil, true): created = try store.quickAdd(text: title, listId: draft.listId, first: true, after: after)
            case (nil, false): created = try store.createTask(new: NewTask(title: title, listId: draft.listId, first: true, after: after))
            }
            if !draft.notes.isEmpty { try store.setNotes(id: created.id, notes: draft.notes) }
            if let start = draft.start { try store.setStart(id: created.id, start: start) }
            // The list gives its date only to a task without a start date, and this one was created before its start was written.
            let bare = draft.dueRemoved || draft.start != nil
            let named = (bare || (draft.priorityChosen && draft.priority == .none)) && parse ? store.parseQuick(text: title) : nil
            let due = draft.due ?? (bare ? named?.due : created.due)
            if due != created.due { try store.setDue(id: created.id, due: due) }
            // After the dates: the rule is counted from them.
            if let rule = draft.repeat { try store.setRepeat(id: created.id, repeat: rule) }
            // Untouched, the field leaves what the core set; "none" takes the default of the list away.
            let priority = !draft.priorityChosen ? created.priority : draft.priority == .none ? named?.priority ?? Priority.none : draft.priority
            if priority != created.priority { try store.setPriority(id: created.id, priority: priority) }
            for tag in draft.tags where !created.tags.contains(tag) { try store.addTag(id: created.id, tag: tag) }
            // R113: the subtasks typed in the card, in their order and with their titles as typed.
            let subtasks = draft.typedSubtasks
            if !subtasks.isEmpty { _ = try store.addSubtasks(parentId: created.id, titles: subtasks) }
            return try store.task(id: created.id)
        }
        if let task {
            attach(draft.files, to: task.id)
            noteUsedList(task.listId)
            if allTasks.contains(where: { $0.id == task.id }) { selection = task.id }
        }
        return task
    }

    /// Copies the files into the task; one that cannot be read is reported and the rest go on.
    func attach(_ urls: [URL], to taskId: String) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            perform { _ = try $0.addAttachment(taskId: taskId, path: url.path, name: nil) }
            if scoped { url.stopAccessingSecurityScopedResource() }
            IncomingFiles.discard(url)
        }
    }

    func showSubtasks(_ id: String) {
        subtasksShown.insert(id)
        expand(id)
    }

    func toggleSubtasks(_ id: String) {
        if subtasksShown.contains(id) { subtasksShown.remove(id) } else { subtasksShown.insert(id) }
    }

    /// A project is its subtasks, so they are on show without asking.
    func showsSubtasks(_ task: TaskItem) -> Bool {
        task.isProject || subtasksShown.contains(task.id)
    }

    /// Whether the task is a subtask: a line with a mark and a title, without a card (R10).
    /// The tasks of a project are full tasks.
    func isSubtask(_ task: TaskItem) -> Bool {
        guard let parent = task.parentId else { return false }
        return (row(parent) ?? (try? store?.task(id: parent)))?.isProject != true
    }

    /// A task among those on screen.
    func row(_ id: String) -> TaskItem? {
        allTasks.first { $0.id == id } ?? children.values.joined().first { $0.id == id }
    }

    /// Starts the edit of the title of a subtask in its line (R38).
    func startRenaming(_ task: TaskItem) {
        // A second double click lands in the text being typed and is not a new start.
        guard renaming != task.id else { return }
        selection = task.id
        renamingTitle = task.title
        renaming = task.id
    }

    /// Ends that edit: Return and leaving the line save the title, Esc does not. An emptied title stays what it was.
    func finishRenaming(_ id: String, save: Bool) {
        guard renaming == id else { return }
        renaming = nil
        listFocusRequests += 1
        // A title has no line breaks: pasted text of several lines becomes one line.
        let title = renamingTitle.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard save, !title.isEmpty, title != row(id)?.title else { return }
        perform { try $0.setTitle(id: id, title: title) }
    }

    /// Opens the card of a task and closes the one that was open. A subtask has no card: it is selected.
    func expand(_ id: String) {
        if let task = row(id), isSubtask(task) { return selection = id }
        if let draft, !draft.isBlank {
            // The table takes the row of the new task first and the open card on the next
            // turn: both in one update make it call back into its delegate.
            finishDraft()
            DispatchQueue.main.async { self.expand(id) }
            return
        }
        finishDraft()
        selection = id
        closeCards(except: id)
        expanded.insert(id)
        reload()
    }

    /// Opens the card for typing, the way Return and a double click do: the caret goes to the title.
    func edit(_ id: String) {
        expand(id)
        titleFocus = id
    }

    /// Closes a card from the keyboard: the row stays selected and the list has the keyboard again.
    func closeCard(_ id: String) {
        collapse(id)
        selection = id
        listFocusRequests += 1
    }

    /// Esc while the list has the keyboard: closes the card the selected row is in, the innermost open one.
    /// False when the selected row is in no open card.
    func closeSelectedCard() -> Bool {
        guard let selection, let open = ([selection] + ancestors(of: selection)).first(where: expanded.contains) else { return false }
        closeCard(open)
        return true
    }

    /// A click outside an open card closes it the way Esc does (R44); the keyboard goes to the list only when
    /// the click leaves it nowhere else, such as on the title of the view or on the toolbar.
    func closeCardByClick(_ id: String, keyboardToList: Bool) {
        guard expanded.contains(id) else { return }
        collapse(id)
        if keyboardToList { listFocusRequests += 1 }
    }

    /// Closes a card together with the cards of the subtasks inside it.
    func collapse(_ id: String) {
        if titleFocus == id { titleFocus = nil }
        if let selection, ancestors(of: selection).contains(id) { self.selection = id }
        expanded.subtract(expanded.filter { ancestors(of: $0).contains(id) })
        expanded.remove(id)
        reload()
    }

    /// The rows a row is drawn inside of, nearest first.
    private func ancestors(of id: String) -> [String] {
        var path: [String] = []
        var current = id
        while let parent = children.first(where: { entry in
            expanded.contains(entry.key) && entry.value.contains { $0.id == current }
        })?.key, !path.contains(parent) {
            path.append(parent)
            current = parent
        }
        return path
    }

    /// Leaves open only the row itself and the rows it is drawn inside of.
    private func closeCards(except id: String) {
        expanded.formIntersection(ancestors(of: id) + [id])
    }

    func toggleDone(_ task: TaskItem) {
        if task.done != nil {
            perform { try $0.reopenTask(id: task.id) }
            return
        }
        // The subtasks closed with the task come back with it on undo; reopening by the mark leaves them (R11).
        // A repeating task gets back its dates and the state of its subtasks (R128).
        perform(named: L("Complete Task")) { _ = try $0.completeTask(id: task.id) }
    }

    /// R126: completes the project whatever the state of its tasks; its open tasks close with it (R11)
    /// and come back with it on undo. The project leaves the sidebar at once.
    func completeProject(_ project: TaskItem) {
        guard project.done == nil else { return }
        perform(named: L("Complete Project")) { _ = try $0.completeTask(id: project.id) }
    }

    /// Closes the task as "won't do" (R69); undone the way a completion is.
    func wontDo(_ task: TaskItem) {
        guard task.done == nil else { return }
        perform(named: L("Won't do")) { _ = try $0.wontDoTask(id: task.id) }
    }

    func delete(_ task: TaskItem) {
        finishRenaming(task.id, save: false)
        perform(named: L("Delete Task")) { try $0.deleteTask(id: task.id) }
        expanded.remove(task.id)
        if selection == task.id { selection = nil }
    }

    /// The due date of one task from its menu or ⌘T; undo gives the former one back, as for several (R117, #299).
    func setDue(_ task: TaskItem, _ due: String?) {
        guard task.due != due else { return }
        perform { try $0.setDue(id: task.id, due: due) }
    }

    /// Shows a task in its list, expanded, with every ancestor expanded too.
    func reveal(_ id: String) {
        guard let store, var task = try? store.task(id: id) else { return }
        finishDraft()
        search = ""
        searchOpen = false
        scope = task.listId == "inbox" ? .inbox : .list(id: task.listId)
        var path = [task.id]
        while let parent = task.parentId, let next = try? store.task(id: parent) {
            path.append(next.id)
            task = next
        }
        // A subtask has no card of its own: the card of its task is the innermost one.
        let subtask = (try? store.task(id: id)).map(isSubtask) ?? false
        // The selection first: it closes every card that is not around the row it lands on.
        selection = id
        expanded = Set(subtask ? Array(path.dropFirst()) : path)
        subtasksShown.formUnion(path.dropFirst())
        reload()
    }

    var selectedTask: TaskItem? {
        selection.flatMap(row)
    }

    /// Rows in the order they are drawn: each task followed by its expanded subtree.
    var visibleIds: [String] {
        func walk(_ tasks: [TaskItem]) -> [String] {
            tasks.flatMap { task in
                [task.id] + (expanded.contains(task.id) && showsSubtasks(task) ? walk(children[task.id] ?? []) : [])
            }
        }
        return walk(visibleSections.flatMap(\.tasks))
    }

    func moveSelection(_ step: Int) {
        let ids = visibleIds
        guard !ids.isEmpty else { return }
        guard let current = selection, let index = ids.firstIndex(of: current) else {
            selection = step > 0 ? ids.first : ids.last
            return
        }
        selection = ids[min(max(index + step, 0), ids.count - 1)]
    }

    // MARK: Several rows (R117)

    func isSelected(_ id: String) -> Bool { picked.isEmpty ? selection == id : picked.contains(id) }

    /// The selected rows in the order they are drawn.
    var selectedIds: [String] { picked.isEmpty ? (selection.map { [$0] } ?? []) : visibleIds.filter(picked.contains) }
    var selectedTasks: [TaskItem] { selectedIds.compactMap(row) }

    private func pick(_ ids: Set<String>, lead: String?) {
        keepsPicked = true
        defer { keepsPicked = false }
        picked = ids.count > 1 ? ids : []
        if selection != lead { selection = lead }
    }

    /// A click on a row: plain, with ⌘ (adds the row or takes it out) or with Shift (the range from the row the last plain click chose).
    func click(_ id: String, command: Bool = false, shift: Bool = false) {
        let ids = visibleIds
        if shift, let from = anchor ?? selection, let a = ids.firstIndex(of: from), let b = ids.firstIndex(of: id) {
            pick(Set(ids[min(a, b)...max(a, b)]), lead: id)
            anchor = from
        } else if command {
            var now = picked.isEmpty ? Set(selection.map { [$0] } ?? []) : picked
            if now.contains(id) { now.remove(id) } else { now.insert(id) }
            let lead = now.contains(id) ? id : selection.flatMap { now.contains($0) ? $0 : nil } ?? ids.first(where: now.contains)
            pick(now, lead: lead)
            anchor = lead
        } else {
            if !picked.isEmpty { picked = [] }
            selection = id
        }
    }

    /// Shift with an arrow key: the range grows or shrinks by a row.
    func extendSelection(_ step: Int) {
        let ids = visibleIds
        guard let lead = selection, let at = ids.firstIndex(of: lead) else { return moveSelection(step) }
        let start = anchor.flatMap { ids.contains($0) ? $0 : nil } ?? lead
        guard let from = ids.firstIndex(of: start) else { return }
        let to = min(max(at + step, 0), ids.count - 1)
        pick(Set(ids[min(from, to)...max(from, to)]), lead: ids[to])
        anchor = start
    }

    func selectAll() {
        let ids = visibleIds
        guard let first = ids.first else { return }
        pick(Set(ids), lead: selection.flatMap { ids.contains($0) ? $0 : nil } ?? first)
        anchor = first
    }

    /// Esc: back to one selected row. False when there was one already.
    func clearPicked() -> Bool {
        guard !picked.isEmpty else { return false }
        picked = []
        return true
    }

    /// A row that left the view leaves the selection.
    private func prunePicked() {
        guard !picked.isEmpty else { return }
        let ids = visibleIds
        let left = picked.intersection(ids)
        guard left != picked else { return }
        pick(left, lead: selection.flatMap { left.contains($0) ? $0 : nil } ?? ids.first(where: left.contains))
    }

    /// R123: what a drag of this row carries: every selected row when it is one of them, the row alone otherwise.
    func dragIds(_ id: String) -> [String] { picked.contains(id) ? selectedIds : [id] }

    /// R123: tasks dropped on a row of the sidebar. False when the row takes no tasks or none of them changed.
    func drop(_ ids: [String], on target: Scope) -> Bool {
        let action: BatchAction
        switch target {
        case .inbox: action = .move(listId: "inbox")
        case .list(let id): action = .move(listId: id)
        case .project(let id): action = .project(id: id)
        case .today: action = .due(Moment.today())
        default: return false
        }
        return batch(action, ids: ids) > 0
    }

    /// One action on every selected row it applies to, or on the rows `ids` names, taken back by one undo.
    /// Returns how many rows it changed.
    @discardableResult
    func batch(_ action: BatchAction, ids: [String]? = nil) -> Int {
        let tasks = ids.map { $0.compactMap(row) } ?? selectedTasks
        let ids = tasks.filter { action.applies(to: $0, subtask: isSubtask($0)) }.map(\.id)
        guard !ids.isEmpty else { return 0 }
        if case .delete = action {
            for id in ids {
                finishRenaming(id, save: false)
                expanded.remove(id)
            }
        }
        perform(named: action.name) { store in for id in ids { try action.run(store, id) } }
        // The row the keys go on from may be gone with the action.
        if picked.isEmpty, let selection, !visibleIds.contains(selection) { self.selection = nil }
        return ids.count
    }

    /// A tag as the core stores it.
    static func cleanTag(_ tag: String) -> String {
        var name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix("#") { name.removeFirst() }
        return name.lowercased()
    }

    /// Asks for the name of a tag and adds it to every selected task.
    func askTagForSelection() {
        let alert = NSAlert()
        alert.messageText = L("New tag…")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L("Add"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        batch(.tag(Self.cleanTag(field.stringValue)))
    }

    func toggleExpanded(_ id: String) {
        if expanded.contains(id) { collapse(id) } else { expand(id) }
    }

    /// Return and a double click: an open card closes, a closed one opens for typing.
    /// A subtask has its title edited in its line.
    func toggleEditing(_ id: String) {
        if let task = row(id), isSubtask(task) { return startRenaming(task) }
        if expanded.contains(id) { closeCard(id) } else { edit(id) }
    }

    /// Reorders within the single section of a manually sorted list.
    func move(from source: IndexSet, to destination: Int) {
        guard canReorder, let tasks = visibleSections.first?.tasks, let from = source.first else { return }
        var order = tasks
        order.move(fromOffsets: source, toOffset: destination)
        let moved = tasks[from]
        guard let index = order.firstIndex(where: { $0.id == moved.id }) else { return }
        let after = index > 0 ? order[index - 1].id : nil
        perform { try $0.moveTask(id: moved.id, listId: nil, parentId: nil, after: after) }
    }

    // MARK: Import

    /// Asks for a file exported from another task manager and imports it.
    func importFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L("A 2Do backup (.2dodb), a Todoist CSV, a Trello board JSON or Microsoft To Do lists as JSON")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let report = perform({ try $0.importFile(path: url.path) }) else { return }
        let summary = L("Imported from %@: %@ lists, %@ tasks, %@ attachments.", report.source, "\(report.lists)", "\(report.tasks)", "\(report.attachments)")
        alertIsError = false
        alert = ([summary] + report.notes).joined(separator: "\n\n")
    }

    // MARK: Sync

    func scheduleSync() {
        // The helper leaves the sync to Lists and tells it, if it is running, that there is something new (R115).
        if LoginItems.isHelper { return Storage.announceChange() }
        syncDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        syncDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// With sync through a folder, a file another program brings into its log
    /// starts a run. Called again after the settings change and after a run,
    /// since the log does not exist before the first one.
    func watchSyncFolder() {
        guard case .folder(let path)? = try? store?.syncConfig() else {
            folderWatcher.watch(nil) {}
            return
        }
        let log = URL(fileURLWithPath: path).appendingPathComponent("lists/log", isDirectory: true)
        folderWatcher.watch(log) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleSync() }
        }
    }

    /// R88: the automatic backup is looked at when the app starts and every minute after, with sync on or off.
    private func backupIfDue() {
        guard let store else { return }
        _Concurrency.Task.detached(priority: .utility) { _ = try? store.backupIfDue() }
    }

    func syncNow() {
        guard let store, syncStatus.configured, !syncing, !LoginItems.isHelper else { return }
        syncing = true
        _Concurrency.Task.detached(priority: .utility) {
            let result = Result { try store.syncNow() }
            await MainActor.run {
                self.syncing = false
                self.watchSyncFolder()
                // A failure is kept in the status and shown by the toolbar icon, never as an alert.
                if case .success(let report) = result, report.pulled > 0 || report.blobsDownloaded > 0 {
                    self.reload()
                    if report.blobsDownloaded > 0 { self.attachmentsArrived += 1 }
                } else if let status = try? store.syncStatus() {
                    self.syncStatus = status
                }
                if case .success = result { self.syncAttachments() }
            }
        }
    }

    /// S34: the content of attachments moves after the fields are on screen,
    /// and the next run for the fields does not wait for it.
    private func syncAttachments() {
        guard let store, !movingAttachments else { return }
        movingAttachments = true
        _Concurrency.Task.detached(priority: .utility) {
            let downloaded = (try? store.syncAttachments())?.downloaded ?? 0
            await MainActor.run {
                self.movingAttachments = false
                self.attachmentsMoved(arrived: downloaded > 0)
            }
        }
    }

    /// R91: asks for a folder and saves every attachment of the task there.
    func saveAllAttachments(of taskId: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Save")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        saveAttachments(of: taskId, into: folder)
    }

    /// Saves every attachment of the task into the folder, those still to arrive after downloading them.
    /// What could not be downloaded or written is named in a message; the rest are saved.
    func saveAttachments(of taskId: String, into folder: URL) {
        guard let store, !savingAttachments.contains(taskId) else { return }
        savingAttachments.insert(taskId)
        _Concurrency.Task.detached(priority: .userInitiated) {
            let result = Result { try store.saveAttachments(taskId: taskId, dir: folder.path) }
            await MainActor.run {
                self.savingAttachments.remove(taskId)
                switch result {
                case .success(let report):
                    #if DEBUG
                    print("debug: saved all \(report.saved), failed \(report.failed), fetched \(report.fetched)")
                    #endif
                    if report.fetched > 0 { self.attachmentsMoved(arrived: true) }
                    guard !report.failed.isEmpty else { return }
                    self.alertIsError = true
                    self.alert = L("Could not save: %@", report.failed.joined(separator: ", "))
                case .failure(let error):
                    self.alertIsError = true
                    self.alert = describe(error)
                }
            }
        }
    }

    /// The count of waiting attachments changed; with `arrived`, content is new on this device.
    func attachmentsMoved(arrived: Bool) {
        if let status = try? store?.syncStatus() { syncStatus = status }
        if arrived { attachmentsArrived += 1 }
    }
}
