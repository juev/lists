import AppKit

/// A subtask in the card of its task: a mark and a title, and no card of its own (R10, R38). A click selects it the way a
/// click selects a row (R117), a double click and Return on the selected line edit its title in place, a right click and
/// a ⌃click open its menu (#201).
@MainActor
final class SubtaskLineView: NSView, NSTextFieldDelegate {
    private(set) var task: TaskItem
    private let mark = TaskMarkButton()
    private let title = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let rowMenu = RowMenu()
    private var selected = false
    private var renaming = false

    private var model: AppModel { AppModel.shared }
    private var locked: Bool { task.deleted || task.isLog }

    init(task: TaskItem) {
        self.task = task
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = L("Title")
        field.delegate = self
        field.isHidden = true
        for view in [mark, title, field] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ task: TaskItem, selected: Bool, renaming: Bool) {
        self.task = task
        self.selected = selected
        mark.configure(task, model: model)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: AppFont.native(.body),
            .foregroundColor: task.done != nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        if task.done != nil { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        title.attributedStringValue = NSAttributedString(string: task.title, attributes: attributes)
        field.font = AppFont.native(.body)
        let started = renaming && !self.renaming
        self.renaming = renaming
        title.isHidden = renaming
        field.isHidden = !renaming
        if started {
            field.stringValue = model.renamingTitle
            // On the next turn: the line is being laid out while the edit starts.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.renaming, let window = self.window else { return }
                window.makeFirstResponder(self.field)
                self.field.currentEditor()?.selectedRange = NSRange(location: self.field.stringValue.utf16.count, length: 0)
            }
        }
        needsDisplay = true
        needsLayout = true
    }

    static var height: CGFloat { TaskTableMetrics.lineHeight(AppFont.native(.body)) + 12 }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let size = mark.fittingSize
        let line = TaskTableMetrics.lineHeight(AppFont.native(.body))
        mark.frame = NSRect(x: 6, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        let x = mark.frame.maxX + 8
        let frame = NSRect(x: x, y: ((bounds.height - line) / 2).rounded(), width: max(bounds.width - x - 6, 0), height: line)
        title.frame = frame
        field.frame = frame.insetBy(dx: 0, dy: -1)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The selection is the same strip as behind a row (R117).
        guard selected else { return }
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            NSMenu.popUpContextMenu(subtaskMenu(), with: event, for: self)
            return
        }
        // The keys go on from the list: the arrows, Return and Space are for the selected line.
        var table = superview
        while let view = table, !(view is TaskTableView) { table = view.superview }
        if let table { window?.makeFirstResponder(table) }
        let flags = event.modifierFlags
        model.click(task.id, command: flags.contains(.command), shift: flags.contains(.shift))
        if event.clickCount == 2, !locked { model.startRenaming(task) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { subtaskMenu() }

    /// The menu of the subtask, built from the same items as the menu of a row of the list.
    func subtaskMenu() -> NSMenu { rowMenu.menu(TaskMenus.subtaskItems(task, model)) }

    // MARK: The title (R38)

    func controlTextDidChange(_ notification: Notification) { model.renamingTitle = field.stringValue }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finish(save: true)
            return true
        // Esc ends the edit and not the card of the task around the line.
        case #selector(NSResponder.cancelOperation(_:)):
            finish(save: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) { finish(save: true) }

    /// Saves the title, or leaves it as it was; Return, Esc and leaving the line all end up here.
    func finish(save: Bool) {
        guard renaming else { return }
        model.renamingTitle = field.stringValue
        model.finishRenaming(task.id, save: save)
    }
}

/// The subtasks of an open card (R10, R38): the line "Subtasks N/M" that unfolds them, the lines, and the field for a new
/// one. A project has its tasks as rows of the table under its card (R30); its card shows the line alone.
@MainActor
final class CardSubtasksView: NSView {
    private let header = NSButton()
    private var lines: [String: SubtaskLineView] = [:]
    private var order: [SubtaskLineView] = []
    private let plus = NSImageView()
    private let field = NSTextField()
    private var task: TaskItem?
    private var state = CardLines(subtasks: [], shown: false, selected: [], renaming: nil)
    private var observer: NSObjectProtocol?

    private var model: AppModel { AppModel.shared }

    override init(frame: NSRect) {
        super.init(frame: frame)
        header.isBordered = false
        header.target = self
        header.action = #selector(toggle)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = L("Subtask")
        field.target = self
        field.action = #selector(add)
        plus.contentTintColor = .tertiaryLabelColor
        for view in [header, plus, field] as [NSView] { addSubview(view) }
        // R83: quitting does not take the keyboard from the title of a subtask.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.order.forEach { $0.finish(save: true) } }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private var hasHeader: Bool { (task?.subtasksTotal ?? 0) > 0 || state.shown }
    private var hasField: Bool {
        guard let task else { return false }
        return state.shown && !task.isProject && !task.deleted && !task.isLog
    }

    var isEmpty: Bool { !hasHeader }

    func configure(_ task: TaskItem, _ state: CardLines) {
        self.task = task
        self.state = state
        let caption = AppFont.native(.caption)
        let text = NSMutableAttributedString()
        let attributes: [NSAttributedString.Key: Any] = [.font: caption, .foregroundColor: NSColor.secondaryLabelColor]
        if let chevron = NSImage.symbol(state.shown ? "chevron.down" : "chevron.right", caption) {
            let attachment = NSTextAttachment()
            attachment.image = chevron
            attachment.bounds = NSRect(x: 0, y: (caption.capHeight - chevron.size.height) / 2, width: chevron.size.width, height: chevron.size.height)
            text.append(NSAttributedString(attachment: attachment))
        }
        text.append(NSAttributedString(string: "  " + L("Subtasks"), attributes: attributes))
        if task.subtasksTotal > 0 {
            text.append(NSAttributedString(string: "  \(task.subtasksDone)/\(task.subtasksTotal)", attributes: [.font: caption.monospacedDigits, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: text.length))
        header.attributedTitle = text
        // A project is its subtasks: they are on show without asking.
        header.isEnabled = !task.isProject
        header.isHidden = !hasHeader

        let ids = Set(state.subtasks.map(\.id))
        for (id, line) in lines where !ids.contains(id) {
            line.removeFromSuperview()
            lines[id] = nil
        }
        order = state.subtasks.map { child in
            let line = lines[child.id] ?? SubtaskLineView(task: child)
            lines[child.id] = line
            if line.superview !== self { addSubview(line) }
            line.configure(child, selected: state.selected.contains(child.id), renaming: state.renaming == child.id)
            return line
        }
        field.font = AppFont.native(.callout)
        plus.image = .symbol("plus.circle", AppFont.native(.callout))
        field.isHidden = !hasField
        plus.isHidden = !hasField
        needsLayout = true
    }

    /// Opens the field of a new subtask, the way the chip of subtasks and "Add subtask" do.
    func focusField() {
        guard hasField else { return }
        window?.makeFirstResponder(field)
    }

    @objc private func toggle() {
        guard let task else { return }
        model.toggleSubtasks(task.id)
    }

    @objc private func add() {
        guard let task, !field.stringValue.isEmpty else { return }
        if model.add(field.stringValue, parent: task.id) != nil { field.stringValue = "" }
        window?.makeFirstResponder(field)
    }

    // MARK: Layout

    private let gap: CGFloat = 6
    private var headerHeight: CGFloat { TaskTableMetrics.lineHeight(AppFont.native(.caption)) + 2 }
    private var fieldHeight: CGFloat { TaskTableMetrics.lineHeight(AppFont.native(.callout)) + 2 }

    var height: CGFloat {
        guard hasHeader else { return 0 }
        var height = headerHeight
        height += CGFloat(order.count) * (SubtaskLineView.height + gap)
        if hasField { height += gap + fieldHeight }
        return height
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // The line and the field stand under the note; the subtasks a little to the left of them, at their marks.
        header.frame = NSRect(x: 0, y: 0, width: min(header.fittingSize.width, bounds.width), height: headerHeight)
        var y = headerHeight
        for line in order {
            y += gap
            line.frame = NSRect(x: -12, y: y, width: bounds.width + 12, height: SubtaskLineView.height)
            y += SubtaskLineView.height
        }
        if hasField {
            y += gap
            let size = plus.image?.size ?? .zero
            plus.frame = NSRect(x: 0, y: y + ((fieldHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
            field.frame = NSRect(x: plus.frame.maxX + 6, y: y, width: max(bounds.width - plus.frame.maxX - 6, 0), height: fieldHeight)
        }
    }
}
