import AppKit
import SwiftUI

/// What the row of a task shows.
struct TaskRowState: Equatable {
    var task: TaskItem
    /// R72: where the task lives, in a view that mixes lists.
    var origin: RowOrigin?
    var dayInHeading: Bool
    var open: Bool
    /// R30, R31: a task of an open project stands under it, moved to the right.
    var depth = 0
    /// What an open card shows of its subtasks (R10, R38).
    var lines: CardLines?
}

/// The subtasks of an open card as the card draws them.
struct CardLines: Equatable {
    /// The subtasks on show: none while they are folded behind their line, none for a project, whose tasks are rows.
    var subtasks: [TaskItem]
    var shown: Bool
    /// The subtasks among the selected rows (R117).
    var selected: Set<String>
    /// The subtask whose title is being edited in its line (R38).
    var renaming: String?
}

/// A row of the task table (#308).
enum TaskTableRow: Equatable {
    /// R78: the events of the day, above the tasks of Today.
    case events([DayEvent])
    case heading(id: String, title: String)
    case task(TaskRowState)
    /// R22: a subtask a search found the task above by.
    case found(TaskItem, parent: String)
    /// The field for a new task of the open project above (R30).
    case newChild(parent: String, depth: Int)
    /// R37: the card of a new task, where the task is going to stand (R130).
    case draft(TaskDraft)

    /// What tells the row from the others while its content changes.
    var key: String {
        switch self {
        case .events: "events"
        case .heading(let id, _): "heading " + id
        case .task(let state): state.task.id
        case .found(let task, let parent): parent + " " + task.id
        case .newChild(let parent, _): "new " + parent
        case .draft: "draft"
        }
    }

    /// The task a click on the row selects; none for the rows that are not tasks of the view.
    var taskId: String? {
        if case .task(let state) = self { return state.task.id }
        return nil
    }

    /// Whether the row is the open card of its task.
    var isCard: Bool {
        switch self {
        case .task(let state): state.open
        case .draft: true
        default: false
        }
    }

    var task: TaskItem? {
        switch self {
        case .task(let state): state.task
        case .found(let task, _): task
        default: nil
        }
    }

    /// The rows of the view, in the order they are drawn.
    @MainActor
    static func rows(_ model: AppModel) -> [TaskTableRow] {
        var rows: [TaskTableRow] = model.eventsShown ? [.events(model.dayEvents)] : []
        let selected = Set(model.selectedIds)
        func add(_ task: TaskItem, depth: Int) {
            let open = model.expanded.contains(task.id)
            let origin = depth == 0 && model.mixesLists ? model.origin(of: task) : nil
            var lines: CardLines?
            if open {
                let shown = model.showsSubtasks(task)
                let children = model.children[task.id] ?? []
                lines = CardLines(
                    subtasks: shown && !task.isProject ? children : [],
                    shown: shown,
                    selected: selected.intersection(children.map(\.id)),
                    renaming: model.renaming.flatMap { id in children.contains { $0.id == id } ? id : nil })
            }
            rows.append(.task(TaskRowState(task: task, origin: origin, dayInHeading: model.dayInHeading(task), open: open, depth: depth, lines: lines)))
            // R22: the subtasks a search found the task by; an open task shows all of its subtasks instead.
            if !open, let found = model.found[task.id] {
                rows.append(contentsOf: found.map { .found($0, parent: task.id) })
            }
            // R30, R31: the tasks of an open project are tasks with cards of their own, under it.
            if open, task.isProject {
                for child in model.children[task.id] ?? [] { add(child, depth: depth + 1) }
                if !task.deleted && !task.isLog { rows.append(.newChild(parent: task.id, depth: depth + 1)) }
            }
        }
        for section in model.visibleSections {
            if let title = section.title { rows.append(.heading(id: section.id, title: title)) }
            for task in section.tasks { add(task, depth: 0) }
        }
        if let draft = model.draft { rows.insert(.draft(draft), at: draftPlace(draft, in: rows, model)) }
        return rows
    }

    /// R130: the card of a new task stands right under the task it goes under, a subtask standing for its parent, with
    /// whatever that task has under it; without one, before the first task of the view.
    @MainActor
    private static func draftPlace(_ draft: TaskDraft, in rows: [TaskTableRow], _ model: AppModel) -> Int {
        let anchor = draft.after.flatMap(model.row).map { model.isSubtask($0) ? $0.parentId ?? $0.id : $0.id }
        if let anchor, let index = rows.firstIndex(where: { $0.taskId == anchor }), case .task(let state) = rows[index] {
            var end = index + 1
            while end < rows.count {
                switch rows[end] {
                case .found: end += 1
                case .newChild(_, let depth) where depth > state.depth: end += 1
                case .task(let next) where next.depth > state.depth: end += 1
                default: return end
                }
            }
            return end
        }
        return rows.firstIndex { if case .task = $0 { true } else { false } } ?? rows.count
    }
}

/// The list of tasks as an AppKit table (#308). The selection, the keys and the menus of the rows go to the model;
/// the table keeps no state of its own.
struct TaskTable: NSViewRepresentable {
    let model: AppModel
    let rows: [TaskTableRow]
    let selected: Set<String>
    let lead: String?
    /// What sets the fonts and the heights of the rows: the spacing (R122), the size and the design of the text (R35).
    let look: String
    let focusRequests: Int
    /// The task whose card takes the keyboard into its title once it is on screen.
    let titleFocus: String?
    /// The view on screen.
    let scope: Scope
    /// Moves when the content of files has arrived: an open card reads its files again (R76).
    let attachmentsArrived: Int

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
        // R123: rows are dragged onto the sidebar and, in a list sorted by hand, to another place in it.
        table.registerForDraggedTypes([.string])
        table.setDraggingSourceOperationMask([.move, .copy, .generic], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.verticalMotionCanBeginDrag = true
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
            let wasOpen = Set(rows.filter(\.isCard).map(\.key))
            if lookChanged {
                rows = new.rows
                look = new.look
                pruneCards()
                table.reloadData()
            } else if new.rows != rows {
                // Rows that come and go are inserted and removed; the rows that stay keep their views, so an open card
                // keeps what is being typed and the keyboard while a task leaves the view or arrives with a sync.
                let old = rows
                let oldKeys = old.map(\.key)
                let newKeys = new.rows.map(\.key)
                var removed = IndexSet()
                var inserted = IndexSet()
                if oldKeys != newKeys {
                    for change in newKeys.difference(from: oldKeys) {
                        switch change {
                        case .remove(let offset, _, _): removed.insert(offset)
                        case .insert(let offset, _, _): inserted.insert(offset)
                        }
                    }
                }
                rows = new.rows
                pruneCards()
                if !removed.isEmpty || !inserted.isEmpty {
                    table.beginUpdates()
                    table.removeRows(at: removed, withAnimation: [])
                    table.insertRows(at: inserted, withAnimation: [])
                    table.endUpdates()
                }
                // The rows that stayed with new content. A row that opens or closes gets the other view and its height
                // changes in an animation (R38); the others take the new content in place.
                let before = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
                let changed = rows.indices.filter { !inserted.contains($0) && before[rows[$0].key] != rows[$0] }
                let reshaped = IndexSet(changed.filter { before[rows[$0].key]?.isCard != rows[$0].isCard })
                for index in changed where !reshaped.contains(index) { refresh(index) }
                if !reshaped.isEmpty { table.reloadData(forRowIndexes: reshaped, columnIndexes: [0]) }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = reshaped.isEmpty ? 0 : 0.2
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(changed))
                }
            }
            // A card just opened is brought into sight once it has its height (R38), and takes the keyboard into its
            // title when it was opened for typing.
            if let opened = rows.firstIndex(where: { $0.isCard && !wasOpen.contains($0.key) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak table] in
                    guard let table, opened < table.numberOfRows else { return }
                    table.scrollRowToVisible(opened)
                }
            }
            if let id = model.titleFocus, let card = cards[id] {
                DispatchQueue.main.async { [model] in
                    guard model.titleFocus == id, card.window != nil else { return }
                    model.titleFocus = nil
                    card.focusTitle()
                }
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
            // R117: a view chosen in the sidebar or by ⌘1…⌘6 has the keyboard, so the arrows select its tasks. A table made
            // for the view, after one that held nothing, takes it as well.
            if new.scope != scope {
                scope = new.scope
                takeKeyboard()
            }
            if new.attachmentsArrived != attachmentsArrived {
                attachmentsArrived = new.attachmentsArrived
                for card in cards.values {
                    card.reloadFiles()
                    card.onHeightChange()
                }
            }
        }

        private var scope: Scope?
        private var attachmentsArrived = 0

        /// The keyboard comes to the table once the click in the sidebar is over: the sidebar takes it for itself while
        /// it follows the mouse. The card of a new task keeps it (R37).
        private func takeKeyboard() {
            table?.wantsKeyboard = true
            table?.takeKeyboardIfWanted()
        }

        /// True while a text view, the field editor of a text field, a chip of a card or the row of a file in it has the keyboard.
        private var typing: Bool { Keyboard.text != nil || Keyboard.inCard }

        /// The open cards, kept while they are open: the table may ask for the view of a row again at any time.
        private var cards: [String: TaskCard] = [:]

        private func card(_ state: TaskRowState) -> TaskCard {
            let task = state.task
            if let card = cards[task.id] {
                card.configure(task, lines: state.lines)
                card.depth = state.depth
                return card
            }
            let card = TaskCard(task: task, lines: state.lines)
            card.depth = state.depth
            card.onHeightChange = { [weak self, weak card] in
                guard let self, let card else { return }
                let id = card.task.id
                self.noteHeight { $0.isCard && $0.taskId == id }
            }
            cards[task.id] = card
            return card
        }

        /// How deep the table is in asking the delegate for a view or a height; the calls may nest. A card measured or
        /// configured then may report a new height, and telling the table about it from inside its own call is a
        /// reentrant operation that AppKit warns of and means to stop with an assertion (#357).
        private var answering = 0

        /// Tells the table that the row matching `which` has a new height; from inside a call of the table, once the
        /// call is over. The row is looked up again then, since rows may have moved.
        private func noteHeight(of which: @escaping (TaskTableRow) -> Bool) {
            guard answering == 0 else {
                DispatchQueue.main.async { [weak self] in self?.noteHeight(of: which) }
                return
            }
            guard let table, let row = rows.firstIndex(where: which) else { return }
            table.noteHeightOfRows(withIndexesChanged: [row])
        }

        private func pruneCards() {
            let open = Set(rows.filter(\.isCard).compactMap(\.taskId))
            cards = cards.filter { open.contains($0.key) }
            if !rows.contains(where: { $0.key == "draft" }) { draft = nil }
        }

        /// The card of a new task while it is open (R37).
        private var draft: DraftCard?

        private func draftCard(_ value: TaskDraft) -> DraftCard {
            if let draft {
                draft.sync(value)
                return draft
            }
            let card = DraftCard(draft: value, footer: false, escSaves: true)
            card.onChange = { [model] new in if model.draft != nil { model.draft = new } }
            card.onClose = { [model] in model.draft = nil }
            card.onResize = { [weak self] in self?.noteHeight { $0.key == "draft" } }
            draft = card
            // R37: the keyboard is in the title at once, the panel of quick entry used before or not (#152): the card asks
            // again while it is not given the keyboard.
            for wait in [0.0, 0.05, 0.15, 0.35, 0.75] {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak card] in
                    guard let card, card.window != nil, Keyboard.text == nil, !Keyboard.inCard else { return }
                    card.focusTitle()
                }
            }
            return card
        }

        /// The row takes its new content in the view it has.
        private func refresh(_ index: Int) {
            guard let table, let view = table.view(atColumn: 0, row: index, makeIfNecessary: false) else { return }
            switch rows[index] {
            case .events(let events): (view as? EventsCell)?.configure(events)
            case .heading(_, let title): (view as? HeadingCell)?.configure(title)
            case .task(let state):
                if state.open { (view as? TaskCard)?.configure(state.task, lines: state.lines) } else {
                    (view as? TaskRowCell)?.configure(state, model: model)
                }
            case .found(let task, _): (view as? FoundRowCell)?.configure(task, model: model)
            case .newChild(let parent, let depth): (view as? NewChildCell)?.configure(parent: parent, depth: depth)
            case .draft(let draft): (view as? DraftCard)?.sync(draft)
            }
        }

        /// The selection of the model drawn by the table, which does not choose rows by itself.
        private func showSelection() {
            guard let table else { return }
            let indexes = IndexSet(rows.indices.filter { rows[$0].taskId.map(selected.contains) == true })
            if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
            table.enumerateAvailableRowViews { view, row in
                (view as? TaskRowView)?.isCard = self.row(row)?.isCard == true
            }
        }

        func row(_ index: Int) -> TaskTableRow? { rows.indices.contains(index) ? rows[index] : nil }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            answering += 1
            defer { answering -= 1 }
            switch rows[row] {
            case .events(let events):
                let cell = tableView.makeView(withIdentifier: EventsCell.identifier, owner: nil) as? EventsCell ?? EventsCell()
                cell.configure(events)
                return cell
            case .heading(_, let title):
                let cell = tableView.makeView(withIdentifier: HeadingCell.identifier, owner: nil) as? HeadingCell ?? HeadingCell()
                cell.configure(title)
                return cell
            case .task(let state) where state.open:
                return card(state)
            case .task(let state):
                let cell = tableView.makeView(withIdentifier: TaskRowCell.identifier, owner: nil) as? TaskRowCell ?? TaskRowCell()
                cell.configure(state, model: model)
                return cell
            case .newChild(let parent, let depth):
                let cell = tableView.makeView(withIdentifier: NewChildCell.identifier, owner: nil) as? NewChildCell ?? NewChildCell()
                cell.configure(parent: parent, depth: depth)
                return cell
            case .draft(let draft):
                return draftCard(draft)
            case .found(let task, _):
                let cell = tableView.makeView(withIdentifier: FoundRowCell.identifier, owner: nil) as? FoundRowCell ?? FoundRowCell()
                cell.configure(task, model: model)
                return cell
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = TaskRowView()
            view.isCard = rows[row].isCard
            return view
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            answering += 1
            defer { answering -= 1 }
            return switch rows[row] {
            case .events(let events): TaskTableMetrics.events(events.count)
            case .heading: TaskTableMetrics.heading()
            case .task(let state) where state.open: card(state).height(width: tableView.tableColumns.first?.width ?? tableView.bounds.width)
            case .task(let state): TaskTableMetrics.taskRow(origin: state.origin != nil, spacing: model.rowSpacing)
            case .found: TaskTableMetrics.foundRow()
            case .newChild: TaskTableMetrics.newChildRow()
            case .draft(let draft): draftCard(draft).height(width: tableView.tableColumns.first?.width ?? tableView.bounds.width)
            }
        }

        // MARK: Dragging (R123)

        /// What a drag of the row carries: the ids of the rows, a line each — every selected row when it is one of them.
        /// An open card is not dragged: it takes the pointer for its text.
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard let id = rows[row].taskId, !rows[row].isCard else { return nil }
            let item = NSPasteboardItem()
            item.setString(model.dragIds(id).joined(separator: "\n"), forType: .string)
            return item
        }

        /// R123: what follows the pointer is the title of the row the drag started on and, for several tasks, their number.
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            guard let row = rowIndexes.first, let task = rows[row].task else { return }
            let image = Self.dragImage(title: task.title, count: model.dragIds(task.id).count)
            session.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
                let at = item.draggingFrame.origin
                item.setDraggingFrame(NSRect(origin: at, size: image.size), contents: image)
            }
        }

        static func dragImage(title: String, count: Int) -> NSImage {
            let font = AppFont.native(.body)
            let label = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            let badgeFont = NSFontManager.shared.convert(AppFont.native(.caption), toHaveTrait: .boldFontMask).monospacedDigits
            let badge = NSAttributedString(string: "\(count)", attributes: [.font: badgeFont, .foregroundColor: NSColor.white])
            let textWidth = min(ceil(label.size().width), 240)
            let badgeSize = NSSize(width: ceil(badge.size().width) + 12, height: ceil(badge.size().height) + 2)
            let line = TaskTableMetrics.lineHeight(font)
            let width = 8 + textWidth + (count > 1 ? 6 + badgeSize.width : 0) + 8
            let size = NSSize(width: width, height: line + 8)
            return NSImage(size: size, flipped: false) { rect in
                NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                label.draw(with: NSRect(x: 8, y: 4, width: textWidth, height: line), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                if count > 1 {
                    let box = NSRect(x: 8 + textWidth + 6, y: (rect.height - badgeSize.height) / 2, width: badgeSize.width, height: badgeSize.height)
                    NSColor.controlAccentColor.setFill()
                    NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
                    badge.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 1))
                }
                return true
            }
        }

        /// A drop between rows moves a task in a list sorted by hand; anywhere else the table takes nothing.
        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard model.canReorder, info.draggingSource as AnyObject === tableView, operation == .above, dragged(info).count == 1 else { return [] }
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let id = dragged(info).first else { return false }
            return move(id, toRow: row)
        }

        private func dragged(_ info: any NSDraggingInfo) -> [String] {
            (info.draggingPasteboard.string(forType: .string) ?? "").split(separator: "\n").map(String.init)
        }

        /// Moves the task to the place before the row with that index, the way a drop between rows does.
        @discardableResult
        func move(_ id: String, toRow row: Int) -> Bool {
            // The order of the list counts its tasks alone: the rows of the view above the place that are its tasks.
            let tasks = model.visibleSections.first?.tasks ?? []
            guard let from = tasks.firstIndex(where: { $0.id == id }) else { return false }
            let above = Set(rows.prefix(max(row, 0)).compactMap(\.taskId))
            let to = tasks.filter { above.contains($0.id) }.count
            model.move(from: [from], to: to)
            return true
        }

        /// A card wraps its text at the width of the table.
        func tableViewColumnDidResize(_ notification: Notification) {
            let open = IndexSet(rows.indices.filter { rows[$0].isCard })
            if !open.isEmpty { table?.noteHeightOfRows(withIndexesChanged: open) }
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

    private var keyboardWatch: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyboardWatch = window?.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.keyboardMoved(to: window.firstResponder) }
        }
        takeKeyboardIfWanted()
    }

    /// Set when the table is to have the keyboard as soon as it can: a table made for a new view is not in the window yet.
    var wantsKeyboard = false

    /// Once the click in the sidebar is over: the sidebar takes the keyboard for itself while it follows the mouse.
    /// The card of a new task keeps the keyboard (R37).
    func takeKeyboardIfWanted() {
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.wantsKeyboard, let window = self.window else { return }
                self.wantsKeyboard = false
                if self.model.draft == nil { window.makeFirstResponder(self) }
            }
        }
    }

    /// R44: the keyboard that goes elsewhere in the window, to the sidebar or the search field, closes the open card,
    /// as a click there did. A card that takes the keyboard into one of its fields keeps it inside the table.
    private func keyboardMoved(to responder: NSResponder?) {
        // A popover of the card has a window of its own: what takes the keyboard there stays in the card (R62).
        guard !model.expanded.isEmpty, let view = responder as? NSView, view.window === window else { return }
        // The field editor of a text field stands for the field.
        let owner = ((view as? NSText)?.delegate as? NSView) ?? view
        guard !owner.isDescendant(of: self) else { return }
        DispatchQueue.main.async { [model] in
            for open in model.expanded { model.closeCardByClick(open, keyboardToList: false) }
        }
    }

    // MARK: Clicks (R117)

    override func mouseDown(with event: NSEvent) {
        // ⌃click opens the menu of the row.
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        let index = row(at: convert(event.locationInWindow, from: nil))
        let id = coordinator?.row(index)?.taskId
        let down = NSEvent.mouseLocation
        window?.makeFirstResponder(self)
        // R44: a click on the empty space of the list closes the open card; one on another row selects it, which closes the card.
        if index < 0 {
            for open in model.expanded { model.closeCardByClick(open, keyboardToList: true) }
        }
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
        if case .found = row { return rowMenu.menu(TaskMenus.subtaskItems(task, model)) }
        return rowMenu.menu(TaskMenus.taskItems(for: task, model))
    }
}
