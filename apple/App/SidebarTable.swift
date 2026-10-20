import AppKit
import SwiftUI

/// What the plus of a heading of the sidebar creates.
enum SidebarAdd: Equatable { case list, project, filter }

/// An item of the sidebar: a view to switch to.
struct SidebarItem: Equatable {
    enum Kind: Equatable {
        case builtin, list, tag, filter, archived
        /// R126: the row of a project is a large task; its mark completes it.
        case project(done: UInt32, total: UInt32)
    }

    var scope: Scope
    var title: String
    var symbol: String?
    var tint: Color?
    var count: String?
    /// The count in red: Today with overdue tasks.
    var alert = false
    var kind: Kind
}

/// A row of the sidebar (#308).
enum SidebarRow: Equatable {
    /// A heading; with a section it collapses and expands it (R161).
    case heading(String, add: SidebarAdd?, section: SidebarSection? = nil, folded: Bool = false)
    case item(SidebarItem)

    var item: SidebarItem? {
        if case .item(let item) = self { return item }
        return nil
    }

    /// The rows of the sidebar in their order (R93, R121, R126, R127).
    @MainActor
    static func rows(_ model: AppModel) -> [SidebarRow] {
        var rows: [SidebarRow] = []
        func builtin(_ scope: Scope, count: UInt32, alert: Bool = false) {
            guard model.showsInSidebar(scope) else { return }
            let icon = scope.viewIcon
            rows.append(.item(SidebarItem(
                scope: scope, title: scope.builtinTitle, symbol: icon?.symbol, tint: icon?.tint,
                count: count > 0 ? "\(count)" : nil, alert: alert, kind: .builtin)))
        }
        builtin(.inbox, count: model.counts.inbox)
        builtin(.today, count: model.counts.today, alert: model.counts.overdue > 0)
        builtin(.upcoming, count: model.counts.upcoming)
        builtin(.all, count: 0)
        builtin(.completed, count: 0)
        builtin(.wontDo, count: 0)
        builtin(.trash, count: model.counts.trash)

        // R161: a collapsed section keeps only the row of the open view.
        func heading(_ title: String, add: SidebarAdd?, _ section: SidebarSection) {
            rows.append(.heading(title, add: add, section: section, folded: model.foldedSections.contains(section)))
        }
        func shown<T>(_ items: [T], _ section: SidebarSection, scope: (T) -> Scope) -> [T] {
            SidebarFolding.shown(items, folded: model.foldedSections.contains(section)) { scope($0) == model.scope }
        }

        heading(L("Lists"), add: .list, .lists)
        for list in shown(model.lists.filter({ $0.id != "inbox" && !$0.archived }), .lists, scope: { .list(id: $0.id) }) {
            rows.append(.item(SidebarItem(
                scope: .list(id: list.id), title: list.name, symbol: list.symbol, tint: list.tint,
                count: list.openCount > 0 ? "\(list.openCount)" : nil, kind: .list)))
        }
        if !model.tags.isEmpty {
            heading(L("Tags"), add: nil, .tags)
            for tag in shown(model.tags, .tags, scope: { .tag(name: $0.name) }) {
                rows.append(.item(SidebarItem(scope: .tag(name: tag.name), title: tag.name, symbol: "number", count: "\(tag.openCount)", kind: .tag)))
            }
        }
        // Shown even when empty, as Filters is: the heading is where a project is made (R127).
        heading(L("Projects"), add: .project, .projects)
        for project in shown(model.projects, .projects, scope: { .project(id: $0.id) }) {
            rows.append(.item(SidebarItem(
                scope: .project(id: project.id), title: project.title, tint: model.list(project.listId)?.tint,
                count: "\(project.subtasksDone)/\(project.subtasksTotal)", kind: .project(done: project.subtasksDone, total: project.subtasksTotal))))
        }
        heading(L("Filters"), add: .filter, .filters)
        for filter in shown(model.filters, .filters, scope: { .filter(id: $0.id) }) {
            rows.append(.item(SidebarItem(
                scope: .filter(id: filter.id), title: filter.name, symbol: "line.3.horizontal.decrease.circle",
                count: filter.openCount > 0 ? "\(filter.openCount)" : nil, kind: .filter)))
        }
        let archived = model.lists.filter(\.archived)
        if !archived.isEmpty {
            rows.append(.heading(L("Archived lists"), add: nil))
            for list in archived {
                rows.append(.item(SidebarItem(scope: .list(id: list.id), title: list.name, symbol: "archivebox", kind: .archived)))
            }
        }
        return rows
    }
}

/// The sidebar of the main window as an AppKit table (#308). Its rows
/// draw the selection themselves, as Things does: the chosen view keeps its colour while the keyboard is with the tasks.
struct SidebarTable: NSViewRepresentable {
    let model: AppModel
    let rows: [SidebarRow]
    let scope: Scope
    /// What the size and the design of the text are (R35).
    let look: String
    var configureList: (TaskList) -> Void
    var configureFilter: (SavedFilter) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = SidebarTableView()
        table.coordinator = context.coordinator
        let column = NSTableColumn(identifier: .init("view"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsEmptySelection = true
        table.allowsTypeSelect = false
        table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        // R123: tasks are dropped on a view; the lists are put in order by dragging them.
        table.registerForDraggedTypes([.string, Coordinator.listType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .sourceList
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.update(self)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(self) }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let listType = NSPasteboard.PasteboardType("org.evsyukov.lists.list")

        let model: AppModel
        weak var table: SidebarTableView?
        private(set) var rows: [SidebarRow] = []
        private var look = ""
        private var syncing = false
        var configureList: (TaskList) -> Void = { _ in }
        var configureFilter: (SavedFilter) -> Void = { _ in }

        init(model: AppModel) { self.model = model }

        /// The titles of the rows, for the debug script.
        var titles: [String] {
            rows.map { row in
                switch row {
                case .heading(let title, _, _, let folded): "[\(title)\(folded ? " ▸" : "")]"
                case .item(let item): item.title + (item.count.map { " \($0)" } ?? "")
                }
            }
        }

        func update(_ new: SidebarTable) {
            configureList = new.configureList
            configureFilter = new.configureFilter
            guard let table else { return }
            if new.rows != rows || new.look != look {
                rows = new.rows
                look = new.look
                syncing = true
                table.reloadData()
                syncing = false
            }
            showSelection(new.scope)
        }

        /// The view on screen is the selected row; a search selects none.
        private func showSelection(_ scope: Scope) {
            guard let table else { return }
            let index = model.isSearching ? nil : rows.firstIndex { $0.item?.scope == scope }
            let wanted = index.map { IndexSet(integer: $0) } ?? IndexSet()
            guard table.selectedRowIndexes != wanted else { return }
            syncing = true
            table.selectRowIndexes(wanted, byExtendingSelection: false)
            syncing = false
        }

        #if DEBUG
        /// The rows without a table, for `sidebarshot` of the debug script.
        func use(_ rows: [SidebarRow]) { self.rows = rows }
        #endif

        func row(_ index: Int) -> SidebarRow? { rows.indices.contains(index) ? rows[index] : nil }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            switch rows[row] {
            case .heading(let title, let add, let section, let folded):
                let cell = tableView.makeView(withIdentifier: SidebarHeadingCell.identifier, owner: nil) as? SidebarHeadingCell ?? SidebarHeadingCell()
                cell.configure(
                    title, add: add.map { add in { [weak self] in self?.create(add) } },
                    folded: section.map { _ in folded },
                    toggle: section.map { section in { [weak self] in self?.toggle(section) } })
                return cell
            case .item(let item):
                let cell = tableView.makeView(withIdentifier: SidebarItemCell.identifier, owner: nil) as? SidebarItemCell ?? SidebarItemCell()
                cell.configure(item, model: model)
                return cell
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SidebarRowView() }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let line = TaskTableMetrics.lineHeight(AppFont.native(.body))
            switch rows[row] {
            // As the sidebar of SwiftUI had them at the usual size of text: 32 points a view, 19 a heading;
            // a heading has room above it, so that the sections read as groups (R161).
            case .heading: return TaskTableMetrics.lineHeight(TaskTableMetrics.headingFont) + 5 + SidebarHeadingCell.room
            case .item: return line + 16
            }
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].item != nil }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let table, let item = row(table.selectedRow)?.item else { return }
            model.search = ""
            model.searchOpen = false
            if model.scope != item.scope { model.scope = item.scope }
        }

        /// R161: collapses the section or expands it again.
        func toggle(_ section: SidebarSection) {
            model.foldedSections.formSymmetricDifference([section])
        }

        private func create(_ add: SidebarAdd) {
            switch add {
            case .list: model.creatingList = true
            case .project: model.creatingProject = true
            case .filter: model.creatingFilter = true
            }
        }

        // MARK: Menus

        private let rowMenu = RowMenu()

        func menu(forRow index: Int) -> NSMenu? {
            guard let item = row(index)?.item else { return nil }
            var items: [RowMenuItem] = []
            switch (item.kind, item.scope) {
            case (.builtin, .inbox):
                if let inbox = model.list("inbox") { items = [RowMenuItem(title: L("Configure…")) { [weak self] in self?.configureList(inbox) }] }
            case (.list, .list(let id)):
                guard let list = model.list(id) else { return nil }
                items = [
                    RowMenuItem(title: L("Configure…")) { [weak self] in self?.configureList(list) },
                    RowMenuItem(title: L("Archive")) { [model] in model.perform { try $0.setListArchived(id: id, archived: true) } },
                    .divider,
                    RowMenuItem(title: L("Delete list"), destructive: true) { [model] in model.deleteList(id) },
                ]
            case (.archived, .list(let id)):
                items = [
                    RowMenuItem(title: L("Unarchive")) { [model] in model.perform { try $0.setListArchived(id: id, archived: false) } },
                    RowMenuItem(title: L("Delete list"), destructive: true) { [model] in model.deleteList(id) },
                ]
            case (.project(_, let total), .project(let id)):
                guard let project = model.projects.first(where: { $0.id == id }) else { return nil }
                items = [RowMenuItem(title: L("Complete Project")) { [model] in model.completeProject(project) }]
                // R32: only an empty project; its tasks would become subtasks and lose their fields.
                if total == 0 {
                    items.append(RowMenuItem(title: L("Turn back into a task")) { [model] in model.perform { try $0.setProject(id: id, project: false) } })
                }
            case (.filter, .filter(let id)):
                guard let filter = model.filters.first(where: { $0.id == id }) else { return nil }
                items = [
                    RowMenuItem(title: L("Configure…")) { [weak self] in self?.configureFilter(filter) },
                    RowMenuItem(title: L("Delete filter"), destructive: true) { [model] in model.perform { try $0.deleteFilter(id: id) } },
                ]
            default:
                return nil
            }
            return rowMenu.menu(items)
        }

        // MARK: Dragging (R123)

        /// The lists are put in order by dragging them within their section; a collapsed one is not (R161).
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard !model.foldedSections.contains(.lists), let item = rows[row].item, item.kind == .list, case .list(let id) = item.scope else { return nil }
            let pasteboard = NSPasteboardItem()
            pasteboard.setString(id, forType: Self.listType)
            return pasteboard
        }

        /// The rows that take tasks: Inbox, Today, a list, a project.
        func takesTasks(_ index: Int) -> Bool {
            guard let item = row(index)?.item else { return false }
            switch (item.kind, item.scope) {
            case (.builtin, .inbox), (.builtin, .today), (.list, _), (.project, _): return true
            default: return false
            }
        }

        private var listRows: Range<Int>? {
            let indices = rows.indices.filter { rows[$0].item?.kind == .list }
            guard let first = indices.first, let last = indices.last else { return nil }
            return first..<(last + 2)
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            let pasteboard = info.draggingPasteboard
            if pasteboard.string(forType: Self.listType) != nil {
                guard let range = listRows, range.contains(row) else { return [] }
                if operation == .on { tableView.setDropRow(row, dropOperation: .above) }
                return .move
            }
            guard pasteboard.string(forType: .string) != nil, takesTasks(row) else { return [] }
            if operation == .above { tableView.setDropRow(row, dropOperation: .on) }
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let pasteboard = info.draggingPasteboard
            if let id = pasteboard.string(forType: Self.listType) { return moveList(id, toRow: row) }
            let ids = (pasteboard.string(forType: .string) ?? "").split(separator: "\n").map(String.init)
            return drop(ids, onRow: row)
        }

        /// Tasks dropped on the row with that index.
        @discardableResult
        func drop(_ ids: [String], onRow row: Int) -> Bool {
            guard takesTasks(row), let scope = self.row(row)?.item?.scope else { return false }
            return model.drop(ids, on: scope)
        }

        /// The list put before the row with that index, among the lists.
        @discardableResult
        func moveList(_ id: String, toRow row: Int) -> Bool {
            let visible = model.lists.filter { $0.id != "inbox" && !$0.archived }
            guard let from = visible.firstIndex(where: { $0.id == id }) else { return false }
            let above = Set(rows.prefix(max(row, 0)).compactMap { row -> String? in
                if case .list(let id)? = row.item?.scope, row.item?.kind == .list { return id }
                return nil
            })
            var order = visible
            order.move(fromOffsets: [from], toOffset: visible.filter { above.contains($0.id) }.count)
            guard let index = order.firstIndex(where: { $0.id == id }) else { return false }
            let after = index > 0 ? order[index - 1].id : nil
            model.perform { try $0.moveList(id: id, after: after) }
            return true
        }
    }
}

/// The table of the sidebar: menus of its rows and Esc, as its own methods.
@MainActor
final class SidebarTableView: NSTableView {
    weak var coordinator: SidebarTable.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        coordinator?.menu(forRow: row(at: convert(event.locationInWindow, from: nil)))
    }

    /// Esc while the sidebar has the keyboard: one of several selected rows is left first, then the open card closes (R44, R117).
    override func cancelOperation(_ sender: Any?) {
        let model = AppModel.shared
        if Keyboard.text == nil, model.clearPicked() || model.closeSelectedCard() { return }
        super.cancelOperation(sender)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]) {
            return cancelOperation(nil)
        }
        super.keyDown(with: event)
    }
}

/// A row of the sidebar that draws its selection the same way wherever the keyboard is, as Things does.
final class SidebarRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

/// A heading of the sidebar with the plus that adds to its section; a click on it collapses the section (R161).
@MainActor
final class SidebarHeadingCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebarHeading")
    /// R161: the room above a heading, apart from the last row of the section before it.
    static let room: CGFloat = 14

    private let title = NSTextField(labelWithString: "")
    /// The whole heading as a button: it collapses and expands the section.
    private let fold = NSButton()
    private let chevron = NSImageView()
    private let plus = NSButton()
    private var add: (() -> Void)?
    private var toggle: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        title.textColor = .secondaryLabelColor
        fold.isBordered = false
        fold.title = ""
        fold.target = self
        fold.action = #selector(folded)
        chevron.contentTintColor = .tertiaryLabelColor
        plus.isBordered = false
        plus.target = self
        plus.action = #selector(clicked)
        plus.contentTintColor = .secondaryLabelColor
        // The plus is above the button of the heading, so a click on it creates and does not collapse.
        for view in [fold, title, chevron, plus] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// `folded` is nil for a heading that does not collapse.
    func configure(_ text: String, add: (() -> Void)?, folded: Bool?, toggle: (() -> Void)?) {
        self.add = add
        self.toggle = toggle
        title.font = TaskTableMetrics.headingFont
        title.stringValue = text
        plus.isHidden = add == nil
        plus.image = .symbol("plus", AppFont.native(.body))
        let help = switch text {
        case L("Lists"): L("New list")
        case L("Projects"): L("New project")
        default: L("New filter")
        }
        plus.toolTip = help
        plus.setAccessibilityLabel(help)
        fold.isHidden = folded == nil
        chevron.isHidden = folded == nil
        if let folded {
            chevron.image = .symbol(folded ? "chevron.right" : "chevron.down", TaskTableMetrics.headingFont, weight: .semibold)
            fold.setAccessibilityLabel(text)
            fold.setAccessibilityValue(folded ? L("Collapsed") : L("Expanded"))
        }
        needsLayout = true
    }

    @objc private func clicked() { add?() }

    @objc private func folded() { toggle?() }

    override func layout() {
        super.layout()
        // The title, the plus and the chevron stand at the bottom, next to the rows they head; the room is above.
        let line = TaskTableMetrics.lineHeight(TaskTableMetrics.headingFont)
        let band = bounds.height - Self.room
        func centered(_ size: NSSize, x: CGFloat) -> NSRect {
            NSRect(x: x, y: ((band - size.height) / 2).rounded(), width: size.width, height: size.height)
        }
        var right = bounds.width - 4
        if !chevron.isHidden {
            let size = chevron.image?.size ?? .zero
            chevron.frame = centered(NSSize(width: max(size.width, 12), height: size.height), x: right - max(size.width, 12))
            right = chevron.frame.minX - 6
        }
        if !plus.isHidden {
            let size = plus.image?.size ?? .zero
            plus.frame = centered(size, x: right - size.width)
            right = plus.frame.minX - 4
        }
        title.frame = centered(NSSize(width: max(right - 8, 0), height: line), x: 4)
        fold.frame = bounds
    }
}

/// A view in the sidebar: its icon, its name and how many open tasks it holds; a project has its mark, which completes it (R126).
@MainActor
final class SidebarItemCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebarItem")

    private let icon = NSImageView()
    private let mark = ProjectMarkButton()
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private var alert = false
    private var muted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        title.lineBreakMode = .byTruncatingTail
        count.alignment = .right
        for view in [icon, mark, title, count] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: SidebarItem, model: AppModel) {
        let font = AppFont.native(.body)
        if case .project(let done, let total) = item.kind, case .project(let id) = item.scope {
            icon.isHidden = true
            mark.isHidden = false
            mark.configure(done: done, total: total, tint: item.tint.map(NSColor.init) ?? .controlAccentColor) {
                model.projects.first { $0.id == id }.map(model.completeProject)
            }
        } else {
            icon.isHidden = item.symbol == nil
            mark.isHidden = true
            icon.image = item.symbol.flatMap { .symbol($0, font) }
            icon.contentTintColor = item.tint.map(NSColor.init) ?? .secondaryLabelColor
        }
        title.font = font
        title.stringValue = item.title
        count.font = font.monospacedDigits
        count.stringValue = item.count ?? ""
        count.isHidden = item.count == nil
        alert = item.alert
        muted = item.kind == .archived
        applyColors()
        needsLayout = true
    }

    /// On the selected row the text stays readable over the colour of the selection.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        title.textColor = selected ? .alternateSelectedControlTextColor : muted ? .secondaryLabelColor : .labelColor
        count.textColor = selected ? .alternateSelectedControlTextColor : alert ? .systemRed : .secondaryLabelColor
        if selected { icon.contentTintColor = .alternateSelectedControlTextColor }
    }

    override func layout() {
        super.layout()
        let line = TaskTableMetrics.lineHeight(AppFont.native(.body))
        let height = bounds.height
        func centered(_ size: NSSize, x: CGFloat) -> NSRect { NSRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height) }
        let lead: CGFloat = 4
        let iconWidth: CGFloat = 20
        if !mark.isHidden { mark.frame = centered(NSSize(width: 14, height: 14), x: lead + (iconWidth - 14) / 2) }
        if !icon.isHidden { icon.frame = centered(NSSize(width: iconWidth, height: line), x: lead) }
        let countWidth = count.isHidden ? 0 : count.fittingSize.width
        count.frame = centered(NSSize(width: countWidth, height: line), x: bounds.width - 6 - countWidth)
        let titleX = lead + iconWidth + 6
        title.frame = centered(NSSize(width: max(count.frame.minX - 6 - titleX, 0), height: line), x: titleX)
    }
}

/// R126: the mark of a project in the sidebar, a circle filled by the share of its done tasks; a click completes the project.
@MainActor
final class ProjectMarkButton: NSButton {
    private var done: UInt32 = 0
    private var total: UInt32 = 0
    private var tint: NSColor = .controlAccentColor
    private var complete: () -> Void = {}

    convenience init() {
        self.init(frame: .zero)
        isBordered = false
        title = ""
        target = self
        action = #selector(clicked)
        toolTip = L("Complete Project")
        setAccessibilityLabel(L("Complete Project"))
    }

    func configure(done: UInt32, total: UInt32, tint: NSColor, complete: @escaping () -> Void) {
        (self.done, self.total, self.tint, self.complete) = (done, total, tint, complete)
        needsDisplay = true
    }

    @objc private func clicked() { complete() }

    override func draw(_ dirtyRect: NSRect) {
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        tint.setStroke()
        ring.stroke()
        guard total > 0, done > 0 else { return }
        let fraction = min(Double(done) / Double(total), 1)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let pie = NSBezierPath()
        pie.move(to: center)
        pie.appendArc(withCenter: center, radius: bounds.width / 2 - 3, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
        pie.close()
        tint.setFill()
        pie.fill()
    }
}
