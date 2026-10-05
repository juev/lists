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

    var scope: Scope = .today { didSet { if scope != oldValue { expanded.removeAll(); selection = nil; reload() } } }
    var search = "" { didSet { if search != oldValue { reload() } } }
    var sections: [TaskSection] = []
    var children: [String: [TaskItem]] = [:]
    var expanded: Set<String> = []
    var selection: String?

    var syncStatus = SyncStatus(configured: false, pending: 0, lastOk: nil, lastError: nil)
    var syncing = false
    /// Text size factor and font design chosen in Settings.
    var textScale: Double = UserDefaults.standard.object(forKey: AppFont.scaleKey) as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(textScale, forKey: AppFont.scaleKey) }
    }
    var fontDesign: String = UserDefaults.standard.string(forKey: AppFont.designKey) ?? "default" {
        didSet { UserDefaults.standard.set(fontDesign, forKey: AppFont.designKey) }
    }
    var alert: String?
    /// False while `alert` carries a report rather than a failure.
    var alertIsError = true

    @ObservationIgnored private var syncDebounce: DispatchWorkItem?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored weak var undoManager: UndoManager?

    private init() {
        do {
            store = try Storage.openStore()
            switch try? store?.syncConfig() {
            case .webDav(let url, let user)?, .calDav(let url, let user)?:
                store?.setSyncPassword(password: Keychain.load(account: Keychain.account(url: url, user: user)))
            default: break
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
    }

    // MARK: Reading

    var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    var effectiveScope: Scope { isSearching ? .search(text: search) : scope }

    var allTasks: [TaskItem] { sections.flatMap(\.tasks) }

    func list(_ id: String) -> TaskList? { lists.first { $0.id == id } }

    func listName(_ list: TaskList) -> String { list.id == "inbox" ? L("Inbox") : list.name }

    var scopeTitle: String {
        switch effectiveScope {
        case .inbox: return L("Inbox")
        case .today: return L("Today")
        case .upcoming: return L("Upcoming")
        case .all: return L("All")
        case .completed: return L("Completed")
        case .trash: return L("Trash")
        case .list(let id): return list(id).map(listName) ?? L("List")
        case .tag(let name): return "#\(name)"
        case .search: return L("Search")
        case .project(let id): return projects.first { $0.id == id }?.title ?? L("Project")
        case .filter(let id): return filters.first { $0.id == id }?.name ?? L("Filter")
        }
    }

    /// The list a task created in the current view goes to.
    var targetListId: String? {
        if case .list(let id) = scope { return id }
        return nil
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

    func reload() {
        guard let store else { return }
        do {
            lists = try store.lists()
            tags = try store.tags()
            counts = try store.counts()
            syncStatus = try store.syncStatus()
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
            Reminders.shared.refresh(store)
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
        case .completed:
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
            var task = try store.quickAdd(text: line, listId: targetListId)
            // A task typed into Today belongs to today unless the line says otherwise.
            if case .today = scope, task.due == nil {
                try store.setDue(id: task.id, due: Moment.today())
                task = try store.task(id: task.id)
            }
            if case .tag(let name) = scope {
                try store.addTag(id: task.id, tag: name)
            }
            return task
        }
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
        search = ""
        scope = task.listId == "inbox" ? .inbox : .list(id: task.listId)
        var path = [task.id]
        while let parent = task.parentId, let next = try? store.task(id: parent) {
            path.append(next.id)
            task = next
        }
        expanded.formUnion(path)
        selection = id
        reload()
    }

    var selectedTask: TaskItem? {
        guard let id = selection else { return nil }
        return allTasks.first { $0.id == id } ?? children.values.joined().first { $0.id == id }
    }

    /// Rows in the order they are drawn: each task followed by its expanded subtree.
    private var visibleIds: [String] {
        func walk(_ tasks: [TaskItem]) -> [String] {
            tasks.flatMap { task in [task.id] + (expanded.contains(task.id) ? walk(children[task.id] ?? []) : []) }
        }
        return walk(allTasks)
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
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        reload()
    }

    /// Reorders within the single section of a manually sorted list.
    func move(from source: IndexSet, to destination: Int) {
        guard canReorder, let tasks = sections.first?.tasks, let from = source.first else { return }
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
        expanded.insert(parent.id)
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

    func syncNow() {
        guard let store, syncStatus.configured, !syncing else { return }
        syncing = true
        _Concurrency.Task.detached(priority: .utility) {
            let result = Result { try store.syncNow() }
            await MainActor.run {
                self.syncing = false
                // A failure is kept in the status and shown by the toolbar icon, never as an alert.
                if case .success(let report) = result, report.pulled > 0 || report.blobsDownloaded > 0 {
                    self.reload()
                } else if let status = try? store.syncStatus() {
                    self.syncStatus = status
                }
            }
        }
    }
}
