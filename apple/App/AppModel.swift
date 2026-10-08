import AppKit
import Foundation
import Observation

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
    var counts = Counts(inbox: 0, today: 0, overdue: 0, upcoming: 0, trash: 0)

    var scope: Scope = .today { didSet { if scope != oldValue { expanded.removeAll(); subtasksShown.removeAll(); draft = nil; selection = nil; reload() } } }
    var search = "" { didSet { if search != oldValue { reload() } } }
    var sections: [TaskSection] = []
    /// Minutes a completed task stays in its view; shared by all devices (R68).
    private(set) var keepDone: KeepDone = .seconds(seconds: 5)
    var children: [String: [TaskItem]] = [:]
    var expanded: Set<String> = []
    /// Expanded tasks whose subtasks are on show; they stay folded until asked for.
    var subtasksShown: Set<String> = []
    /// Moving to another row closes the open card: one card is open at a time.
    var selection: String? {
        didSet {
            if titleFocus != selection { titleFocus = nil }
            if let selection, selection != oldValue { closeCards(except: selection) }
        }
    }
    /// The card of a task that does not exist yet, while it is open (⌘N).
    var draft: TaskDraft?
    /// The task whose title takes the keyboard as soon as its card is on screen.
    var titleFocus: String?
    /// Counts the cards closed from the keyboard: each time the list takes the keyboard back.
    var listFocusRequests = 0
    // Sheets of the sidebar; here so that the menu bar can open them too.
    var creatingList = false
    var creatingFilter = false

    var syncStatus = SyncStatus(configured: false, pending: 0, attachmentsWaiting: 0, lastOk: nil, lastError: nil)
    /// Moves when attachment content has arrived: an open card reads its files again (R76).
    var attachmentsArrived = 0
    var syncing = false
    /// Text size factor and font design chosen in Settings.
    /// A launch argument (`-textScale 1.5`) arrives as a string.
    var textScale: Double = UserDefaults.standard.object(forKey: AppFont.scaleKey)
        .flatMap({ ($0 as? Double) ?? ($0 as? String).flatMap(Double.init) }) ?? 1.0 {
        didSet { UserDefaults.standard.set(textScale, forKey: AppFont.scaleKey) }
    }
    var fontDesign: String = UserDefaults.standard.string(forKey: AppFont.designKey) ?? "default" {
        didSet { UserDefaults.standard.set(fontDesign, forKey: AppFont.designKey) }
    }
    /// "system", "light" or "dark" (R61); belongs to this Mac.
    var appearance: String = UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        didSet {
            UserDefaults.standard.set(appearance, forKey: "appearance")
            applyAppearance()
        }
    }
    var alert: String?
    /// False while `alert` carries a report rather than a failure.
    var alertIsError = true

    // Notification settings of this Mac; not synced.
    var notifyEnabled: Bool = UserDefaults.standard.object(forKey: "notifyEnabled") as? Bool ?? true { didSet { saveNotify() } }
    /// Minutes before a timed due date, one notification for each; empty turns these reminders off.
    var notifyLeads: Set<Int> = AppModel.storedLeads() { didSet { saveNotify() } }
    /// `HH:MM`, empty for off.
    var notifyAllDay: String = UserDefaults.standard.string(forKey: "notifyAllDay") ?? "09:00" { didSet { saveNotify() } }
    var notifySummary: String = UserDefaults.standard.string(forKey: "notifySummary") ?? "" { didSet { saveNotify() } }
    var notifySound: Bool = UserDefaults.standard.object(forKey: "notifySound") as? Bool ?? true { didSet { saveNotify() } }
    /// A system alert sound by its name, empty for the standard sound of notifications (R36).
    var notifySoundName: String = UserDefaults.standard.string(forKey: "notifySoundName") ?? "" { didSet { saveNotify() } }
    /// What a notification plays: nil for silence.
    var notifySoundChoice: String? { notifySound ? notifySoundName : nil }

    var notifySettings: NotifySettings {
        NotifySettings(
            enabled: notifyEnabled,
            leadMinutes: notifyLeads.sorted().map(UInt32.init),
            allDayAt: notifyAllDay.isEmpty ? nil : notifyAllDay,
            summaryAt: notifySummary.isEmpty ? nil : notifySummary)
    }

    private func saveNotify() {
        let defaults = UserDefaults.standard
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
        let defaults = UserDefaults.standard
        if let leads = defaults.array(forKey: "notifyLeads") as? [Int] { return Set(leads) }
        if let lead = defaults.object(forKey: "notifyLead") as? Int { return lead < 0 ? [] : [lead] }
        return [15]
    }

    // Editing habits of this Mac; not synced.
    /// Where a new task goes when the view does not say: `inbox`, `last` or a list id.
    var newTaskList: String = UserDefaults.standard.string(forKey: "newTaskList") ?? "inbox" {
        didSet { UserDefaults.standard.set(newTaskList, forKey: "newTaskList") }
    }
    /// Return in the notes starts a new line (Esc finishes); otherwise it finishes editing and ⌥Return starts a line.
    var returnAddsLine: Bool = UserDefaults.standard.object(forKey: "returnAddsLine") == nil || UserDefaults.standard.bool(forKey: "returnAddsLine") {
        didSet { UserDefaults.standard.set(returnAddsLine, forKey: "returnAddsLine") }
    }

    /// Whether the sidebar and the Go menu offer the Completed view on this Mac; not synced.
    var showCompletedView: Bool = UserDefaults.standard.object(forKey: "showCompletedView") == nil || UserDefaults.standard.bool(forKey: "showCompletedView") {
        didSet {
            UserDefaults.standard.set(showCompletedView, forKey: "showCompletedView")
            if !showCompletedView, scope == .completed || scope == .wontDo { scope = .inbox }
        }
    }

    /// Whether dates, priority, tags and a list are picked out of the typed title.
    var parseQuickText: Bool = UserDefaults.standard.object(forKey: "parseQuickText") == nil || UserDefaults.standard.bool(forKey: "parseQuickText") {
        didSet { UserDefaults.standard.set(parseQuickText, forKey: "parseQuickText") }
    }
    /// Whether quick entry starts the note with what is on the clipboard (R58).
    var clipboardNotes: Bool = UserDefaults.standard.object(forKey: "clipboardNotes") == nil || UserDefaults.standard.bool(forKey: "clipboardNotes") {
        didSet { UserDefaults.standard.set(clipboardNotes, forKey: "clipboardNotes") }
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

    var defaultListId: String {
        let id = newTaskList == "last" ? UserDefaults.standard.string(forKey: "lastUsedList") ?? "inbox" : newTaskList
        return lists.contains { $0.id == id && !$0.archived } ? id : "inbox"
    }

    func noteUsedList(_ id: String) {
        UserDefaults.standard.set(id, forKey: "lastUsedList")
    }

    @ObservationIgnored private var syncDebounce: DispatchWorkItem?
    @ObservationIgnored private var movingAttachments = false
    @ObservationIgnored private var timer: Timer?
    /// Fires when the first of the kept completed tasks is due to leave its view (R68).
    @ObservationIgnored private var keptTimer: Timer?
    @ObservationIgnored private let folderWatcher = FolderWatcher()
    @ObservationIgnored weak var undoManager: UndoManager?

    private init() {
        do {
            store = try Storage.openStore()
            switch try? store?.syncConfig() {
            case .webDav(let url, let user)?, .calDav(let url, let user)?:
                store?.setSyncPassword(password: Keychain.load(account: Keychain.account(url: url, user: user)))
            default: break
            }
            if let server = try? store?.pushServer() {
                store?.setPushToken(token: Keychain.load(account: Keychain.pushAccount(server: server)))
            }
        } catch {
            store = nil
            startupError = describe(error)
        }
        reload()
        DistributedNotificationCenter.default().addObserver(
            forName: Storage.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(); self?.scheduleSync() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(); self?.syncNow() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow() }
        }
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

    /// The sections as they are drawn. Today, Upcoming and a search list a subtask as a
    /// row of its own; while it is on show inside the open card of its parent that row is left out.
    var visibleSections: [TaskSection] {
        func inside(_ tasks: [TaskItem]) -> [String] {
            tasks.flatMap { task -> [String] in
                guard expanded.contains(task.id), showsSubtasks(task) else { return [] }
                let subtasks = children[task.id] ?? []
                return subtasks.map(\.id) + inside(subtasks)
            }
        }
        let nested = Set(inside(allTasks))
        guard !nested.isEmpty else { return sections }
        return sections.compactMap { section in
            var section = section
            section.tasks.removeAll { nested.contains($0.id) }
            return section.tasks.isEmpty ? nil : section
        }
    }

    func list(_ id: String) -> TaskList? { lists.first { $0.id == id } }

    func listName(_ list: TaskList) -> String { list.id == "inbox" ? L("Inbox") : list.name }

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
        do {
            lists = try store.lists()
            tags = try store.tags()
            counts = try store.counts()
            syncStatus = try store.syncStatus()
            keepDone = try store.keepDone()
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
            Reminders.shared.refresh(store, settings: notifySettings, sound: notifySoundChoice)
        } catch {
            alert = describe(error)
        }
    }

    private func group(_ tasks: [TaskItem]) -> [TaskSection] {
        switch effectiveScope {
        case .today:
            let today = Moment.today()
            let overdue = tasks.filter { Moment.day($0.due ?? $0.start ?? today) < today }
            let rest = tasks.filter { Moment.day($0.due ?? $0.start ?? today) >= today }
            if overdue.isEmpty { return [TaskSection(id: "today", title: nil, tasks: rest)] }
            return [
                TaskSection(id: "overdue", title: L("Overdue"), tasks: overdue),
                TaskSection(id: "today", title: L("Today"), tasks: rest),
            ].filter { !$0.tasks.isEmpty }
        case .upcoming:
            return sectioned(tasks, key: { Moment.day($0.due ?? $0.start ?? "") }, title: Moment.heading)
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

    /// Runs a change, then refreshes what is on screen and queues a sync.
    @discardableResult
    func perform<T>(_ change: (Store) throws -> T) -> T? {
        guard let store else { return nil }
        do {
            let result = try change(store)
            reload()
            scheduleSync()
            return result
        } catch {
            alertIsError = true
            alert = describe(error)
            reload()
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
                return try store.quickAddUnder(text: line, parentId: id)
            }
            let task = try store.quickAdd(text: line, listId: targetListId)
            noteUsedList(task.listId)
            return task
        }
    }

    /// Opens the card of a new task. The view gives it its list or its parent
    /// and nothing else (R75).
    func startDraft() {
        search = ""
        switch scope {
        case .completed, .wontDo, .trash: scope = .inbox
        default: break
        }
        var new = TaskDraft(listId: targetListId)
        if case .project(let id) = scope { new.parentId = id }
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
        let task: TaskItem? = perform { store in
            let created: TaskItem
            switch (draft.parentId, parse) {
            case (let parent?, true): created = try store.quickAddUnder(text: title, parentId: parent)
            case (let parent?, false): created = try store.createTask(new: NewTask(title: title, parentId: parent))
            case (nil, true): created = try store.quickAdd(text: title, listId: draft.listId)
            case (nil, false): created = try store.createTask(new: NewTask(title: title, listId: draft.listId))
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

    /// Opens the card of a task and closes the one that was open.
    func expand(_ id: String) {
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
        perform { _ = try $0.completeTask(id: task.id) }
        // A repeating task moves on instead of closing; there is nothing to undo by reopening.
        if task.repeat == nil {
            undoManager?.registerUndo(withTarget: self) { model in
                model.perform { try $0.reopenTask(id: task.id) }
            }
            undoManager?.setActionName(L("Complete Task"))
        }
    }

    /// Closes the task as "won't do" (R69); undone the way a completion is.
    func wontDo(_ task: TaskItem) {
        guard task.done == nil else { return }
        perform { _ = try $0.wontDoTask(id: task.id) }
        if task.repeat == nil {
            undoManager?.registerUndo(withTarget: self) { model in
                model.perform { try $0.reopenTask(id: task.id) }
            }
            undoManager?.setActionName(L("Won't do"))
        }
    }

    func delete(_ task: TaskItem) {
        perform { try $0.deleteTask(id: task.id) }
        expanded.remove(task.id)
        if selection == task.id { selection = nil }
        undoManager?.registerUndo(withTarget: self) { model in
            model.perform { try $0.restoreTask(id: task.id) }
        }
        undoManager?.setActionName(L("Delete Task"))
    }

    func setDue(_ task: TaskItem, _ due: String?) {
        perform { try $0.setDue(id: task.id, due: due) }
    }

    /// Shows a task in its list, expanded, with every ancestor expanded too.
    func reveal(_ id: String) {
        guard let store, var task = try? store.task(id: id) else { return }
        finishDraft()
        search = ""
        scope = task.listId == "inbox" ? .inbox : .list(id: task.listId)
        var path = [task.id]
        while let parent = task.parentId, let next = try? store.task(id: parent) {
            path.append(next.id)
            task = next
        }
        // The selection first: it closes every card that is not around the row it lands on.
        selection = id
        expanded = Set(path)
        subtasksShown.formUnion(path.dropFirst())
        reload()
    }

    var selectedTask: TaskItem? {
        guard let id = selection else { return nil }
        return allTasks.first { $0.id == id } ?? children.values.joined().first { $0.id == id }
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

    func toggleExpanded(_ id: String) {
        if expanded.contains(id) { collapse(id) } else { expand(id) }
    }

    /// Return and a double click: an open card closes, a closed one opens for typing.
    func toggleEditing(_ id: String) {
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

    /// Makes the task a subtask of the one above it in the same level.
    func indent(_ task: TaskItem) {
        let siblings = task.parentId.flatMap { children[$0] } ?? allTasks.filter { $0.parentId == nil }
        guard let index = siblings.firstIndex(where: { $0.id == task.id }), index > 0 else { return }
        let parent = siblings[index - 1]
        // The parent opens to show where the task went; the task keeps its own card if it had one.
        let open = expanded.contains(task.id)
        closeCards(except: parent.id)
        expanded.insert(parent.id)
        if open { expanded.insert(task.id) }
        subtasksShown.insert(parent.id)
        perform { store in
            let last = try store.subtasks(parentId: parent.id).last?.id
            try store.moveTask(id: task.id, listId: nil, parentId: parent.id, after: last)
        }
    }

    /// Moves a subtask one level up, right after its former parent.
    func outdent(_ task: TaskItem) {
        guard let parentId = task.parentId else { return }
        perform { store in
            let parent = try store.task(id: parentId)
            try store.moveTask(id: task.id, listId: nil, parentId: parent.parentId, after: parent.id)
        }
        // The task has left its parent, so the parent's card is no longer around the selection.
        if let selection { closeCards(except: selection) }
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
        let log = URL(fileURLWithPath: path).appendingPathComponent("lists/v1/log", isDirectory: true)
        folderWatcher.watch(log) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleSync() }
        }
    }

    func syncNow() {
        guard let store, syncStatus.configured, !syncing else { return }
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

    /// The count of waiting attachments changed; with `arrived`, content is new on this device.
    func attachmentsMoved(arrived: Bool) {
        if let status = try? store?.syncStatus() { syncStatus = status }
        if arrived { attachmentsArrived += 1 }
    }
}
