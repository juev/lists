import AppKit
import SwiftUI

/// A row of the task table (#308).
enum TaskTableRow: Equatable {
    /// R78: the events of the day, above the tasks of Today.
    case events([DayEvent])
    case heading(id: String, title: String)
    case task(TaskItem, origin: RowOrigin?, dayInHeading: Bool, open: Bool)
    /// R22: a subtask a search found the task above by.
    case found(TaskItem, parent: String)

    /// What tells the row from the others while its content changes.
    var key: String {
        switch self {
        case .events: "events"
        case .heading(let id, _): "heading " + id
        case .task(let task, _, _, _): task.id
        case .found(let task, let parent): parent + " " + task.id
        }
    }

    /// The task a click on the row selects; none for the rows that are not tasks of the view.
    var taskId: String? {
        if case .task(let task, _, _, _) = self { return task.id }
        return nil
    }

    var task: TaskItem? {
        switch self {
        case .task(let task, _, _, _), .found(let task, _): task
        default: nil
        }
    }

    /// The rows of the view, in the order they are drawn.
    @MainActor
    static func rows(_ model: AppModel) -> [TaskTableRow] {
        var rows: [TaskTableRow] = model.eventsShown ? [.events(model.dayEvents)] : []
        for section in model.visibleSections {
            if let title = section.title { rows.append(.heading(id: section.id, title: title)) }
            for task in section.tasks {
                let open = model.expanded.contains(task.id)
                let origin = model.mixesLists ? model.origin(of: task) : nil
                rows.append(.task(task, origin: origin, dayInHeading: model.dayInHeading(task), open: open))
                // R22: the subtasks a search found the task by; an open task shows all of its subtasks instead.
                if !open, let lines = model.found[task.id] {
                    rows.append(contentsOf: lines.map { .found($0, parent: task.id) })
                }
            }
        }
        return rows
    }
}

/// The list of tasks as an AppKit table (#308), behind the launch flag `-TaskTable YES` until it does all the list did.
/// The selection, the keys and the menus of the rows go to the model; the table keeps no state of its own.
struct TaskTable: NSViewRepresentable {
    /// Whether the main window shows the table in place of the SwiftUI list.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "TaskTable") }

    let model: AppModel
    let rows: [TaskTableRow]
    let selected: Set<String>
    let lead: String?
    /// What sets the fonts and the heights of the rows: the spacing (R122), the size and the design of the text (R35).
    let look: String
    let focusRequests: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = TaskTableView()
        table.coordinator = context.coordinator
        let column = NSTableColumn(identifier: .init("task"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = false
        table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.update(self)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: AppModel
        weak var table: TaskTableView?
        private(set) var rows: [TaskTableRow] = []
        private var selected: Set<String> = []
        private var lead: String?
        private var look = ""
        private var focusRequests = 0

        init(model: AppModel) { self.model = model }

        func update(_ new: TaskTable) {
            guard let table else { return }
            let lookChanged = new.look != look
            if lookChanged || new.rows.map(\.key) != rows.map(\.key) {
                rows = new.rows
                look = new.look
                table.reloadData()
            } else if new.rows != rows {
                // The same rows with new content: each changed one draws itself again and the table learns its height.
                let changed = IndexSet(new.rows.indices.filter { new.rows[$0] != rows[$0] })
                rows = new.rows
                table.reloadData(forRowIndexes: changed, columnIndexes: [0])
                table.noteHeightOfRows(withIndexesChanged: changed)
            }
            let leadMoved = new.lead != lead
            selected = new.selected
            lead = new.lead
            showSelection()
            if leadMoved, let lead, let row = rows.firstIndex(where: { $0.taskId == lead }) {
                table.scrollRowToVisible(row)
                if !typing { table.window?.makeFirstResponder(table) }
            }
            if new.focusRequests != focusRequests {
                focusRequests = new.focusRequests
                table.window?.makeFirstResponder(table)
            }
        }

        /// True while a text view, the field editor of a text field, a chip of a card or the row of a file in it has the keyboard.
        private var typing: Bool { Keyboard.text != nil || Keyboard.inCard }

        /// The selection of the model drawn by the table, which does not choose rows by itself.
        private func showSelection() {
            guard let table else { return }
            let indexes = IndexSet(rows.indices.filter { rows[$0].taskId.map(selected.contains) == true })
            if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
            table.enumerateAvailableRowViews { view, row in
                (view as? TaskRowView)?.isCard = self.rows.indices.contains(row) && { if case .task(_, _, _, true) = self.rows[row] { true } else { false } }()
            }
        }

        func row(_ index: Int) -> TaskTableRow? { rows.indices.contains(index) ? rows[index] : nil }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            switch rows[row] {
            case .events(let events):
                let cell = tableView.makeView(withIdentifier: EventsCell.identifier, owner: nil) as? EventsCell ?? EventsCell()
                cell.configure(events)
                return cell
            case .heading(_, let title):
                let cell = tableView.makeView(withIdentifier: HeadingCell.identifier, owner: nil) as? HeadingCell ?? HeadingCell()
                cell.configure(title)
                return cell
            case .task(let task, let origin, let dayInHeading, _):
                let cell = tableView.makeView(withIdentifier: TaskRowCell.identifier, owner: nil) as? TaskRowCell ?? TaskRowCell()
                cell.configure(task, origin: origin, dayInHeading: dayInHeading, model: model)
                return cell
            case .found(let task, _):
                let cell = tableView.makeView(withIdentifier: FoundRowCell.identifier, owner: nil) as? FoundRowCell ?? FoundRowCell()
                cell.configure(task, model: model)
                return cell
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = TaskRowView()
            if case .task(_, _, _, true) = rows[row] { view.isCard = true }
            return view
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            switch rows[row] {
            case .events(let events): TaskTableMetrics.events(events.count)
            case .heading: TaskTableMetrics.heading()
            case .task(_, let origin, _, _): TaskTableMetrics.taskRow(origin: origin != nil, spacing: model.rowSpacing)
            case .found: TaskTableMetrics.foundRow()
            }
        }

        /// The table chooses no rows by itself: a click and the keys go to the model, which hands the selection back.
        func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
            tableView.selectedRowIndexes
        }
    }
}

/// The table of the task list. Clicks, keys and the menus of the rows are its own methods, so no event of the window is
/// looked at on the way (#307).
@MainActor
final class TaskTableView: NSTableView {
    weak var coordinator: TaskTable.Coordinator?

    private var model: AppModel { AppModel.shared }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Clicks (R117)

    override func mouseDown(with event: NSEvent) {
        // ⌃click opens the menu of the row.
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        let id = coordinator?.row(row(at: convert(event.locationInWindow, from: nil)))?.taskId
        let down = NSEvent.mouseLocation
        window?.makeFirstResponder(self)
        // The table follows the mouse until the button goes up; a drag starts from here (R123).
        super.mouseDown(with: event)
        guard let id else { return }
        // A click counts only when the button went up where it went down: a drag changes no selection.
        let up = NSEvent.mouseLocation
        guard NSEvent.pressedMouseButtons & 1 == 0, hypot(up.x - down.x, up.y - down.y) < 4 else { return }
        let flags = event.modifierFlags
        model.click(id, command: flags.contains(.command), shift: flags.contains(.shift))
        if event.clickCount == 2 { model.toggleEditing(id) }
    }

    // MARK: Keys (R117)

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if (event.keyCode == 125 || event.keyCode == 126) && flags.isSubset(of: [.shift]) {
            let step = event.keyCode == 126 ? -1 : 1
            // R117: with Shift the arrows grow and shrink the selection.
            if flags.contains(.shift) { model.extendSelection(step) } else { model.moveSelection(step) }
            return
        }
        guard flags.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76:
            guard let id = model.selection else { return super.keyDown(with: event) }
            // R117: several selected rows have no card to open.
            if model.picked.isEmpty { model.toggleEditing(id) }
        case 49:
            guard let task = model.selectedTask else { return super.keyDown(with: event) }
            if model.picked.isEmpty { model.toggleDone(task) } else { model.batch(.complete) }
        case 53:
            // R117: with several rows selected Esc leaves one of them selected first.
            if !(model.clearPicked() || model.closeSelectedCard()) { super.keyDown(with: event) }
        case 51, 117:
            deleteSelected()
        default:
            super.keyDown(with: event)
        }
    }

    /// R117: ⌘A from the Edit menu selects every row of the view.
    override func selectAll(_ sender: Any?) { model.selectAll() }

    /// Delete in the Edit menu.
    @objc func delete(_ sender: Any?) { deleteSelected() }

    private func deleteSelected() {
        if model.picked.isEmpty { model.selectedTask.map(model.delete) } else { model.batch(.delete) }
    }

    // MARK: Menus (R69, R117, R129)

    private let rowMenu = RowMenu()

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let row = coordinator?.row(row(at: convert(event.locationInWindow, from: nil))), let task = row.task else { return nil }
        if case .found = row { return rowMenu.menu(SubtaskRow.menuItems(task, model)) }
        return rowMenu.menu(TaskRow.menuItems(for: task, model))
    }
}

/// A menu of AppKit built from the items of the menu of a task, which keeps the actions of its items.
@MainActor
final class RowMenu: NSObject {
    private var actions: [() -> Void] = []

    func menu(_ items: [RowMenuItem]) -> NSMenu {
        actions = []
        return build(items)
    }

    private func build(_ items: [RowMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.isDivider {
                menu.addItem(.separator())
                continue
            }
            if item.isHeader {
                menu.addItem(.sectionHeader(title: item.title))
                continue
            }
            let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            if let children = item.children {
                entry.submenu = build(children)
            } else {
                entry.action = #selector(run(_:))
                entry.target = self
                entry.tag = actions.count
                actions.append(item.action)
                entry.state = item.on == true ? .on : .off
                entry.isEnabled = !item.disabled
            }
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func run(_ item: NSMenuItem) {
        if actions.indices.contains(item.tag) { actions[item.tag]() }
    }
}
