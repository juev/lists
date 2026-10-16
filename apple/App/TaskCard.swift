import AppKit

/// The title of an open card (R73): wraps and is read in full, has no line breaks of its own; Return saves it,
/// Esc closes the card (R44), Tab goes on to the note.
@MainActor
final class CardTitleView: NSTextView {
    var onReturn: () -> Void = {}
    var onEscape: () -> Void = {}
    var onTab: () -> Void = {}

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)), #selector(insertLineBreak(_:)): onReturn()
        case #selector(cancelOperation(_:)): onEscape()
        case #selector(insertTab(_:)): onTab()
        default: super.doCommand(by: selector)
        }
    }
}

/// The open card of a task in the task table (#308): the row of the task with its title to edit, and under it the note
/// (R38, R44, R73, R83). The card is drawn apart from the rows by its outline; it keeps what is being typed while the
/// table draws it again, and saves the title and the note when they lose the keyboard, when the card closes and when
/// the app quits or steps back.
@MainActor
final class TaskCard: NSView, NSTextViewDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("card")

    /// Space around the outline, and inside it around the content (the list before it had the same).
    private static let margin: CGFloat = 8
    private static let padding = NSEdgeInsets(top: 10, left: 10, bottom: 14, right: 10)
    /// The note starts under the title, past the mark and the bar.
    private static let notesIndent: CGFloat = 34

    private(set) var task: TaskItem
    /// The height changed with the text: the table learns it.
    var onHeightChange: () -> Void = {}

    private let outline = CardOutline()
    private let mark = TaskMarkButton()
    private let bar = FillView()
    private let folder = NSImageView()
    private let title = CardTitleView()
    private let notes = NotesTextView.PlainTextView()
    private let placeholder = NSTextField(labelWithString: L("Notes"))
    private var observers: [NSObjectProtocol] = []

    private var locked: Bool { task.deleted || task.isLog }

    init(task: TaskItem) {
        self.task = task
        super.init(frame: .zero)
        identifier = Self.identifier
        bar.radius = 1.5
        for view in [outline, mark, bar, folder] as [NSView] { addSubview(view) }

        title.delegate = self
        title.drawsBackground = false
        title.isRichText = false
        title.allowsUndo = true
        title.textContainerInset = .zero
        title.textContainer?.lineFragmentPadding = 0
        title.textContainer?.widthTracksTextView = true
        title.isVerticallyResizable = false
        title.isHorizontallyResizable = false
        title.setAccessibilityLabel(L("Title"))
        title.onReturn = { [weak self] in self?.commitTitle() }
        title.onEscape = { [weak self] in self?.close() }
        title.onTab = { [weak self] in self?.focusNotes() }
        addSubview(title)

        notes.prepare()
        notes.delegate = self
        notes.allowsUndo = true
        notes.drawsBackground = false
        notes.textContainerInset = .zero
        notes.textContainer?.lineFragmentPadding = 0
        notes.textContainer?.widthTracksTextView = true
        notes.isVerticallyResizable = false
        notes.isHorizontallyResizable = false
        // The binding gets the new text first; the note is saved right after it.
        notes.onToggle = { [weak self] in DispatchQueue.main.async { self?.commitNotes() } }
        placeholder.textColor = .tertiaryLabelColor
        addSubview(placeholder)
        addSubview(notes)

        // R83: quitting does not take the keyboard from the title or the note, and neither does another app coming forward.
        for name in [NSApplication.willTerminateNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.commit(leaving: false) }
            })
        }
        configure(task)
        title.string = task.title
        notes.setText(task.notes)
        placeholder.isHidden = !task.notes.isEmpty
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Takes the new state of the task; what is being typed stays.
    func configure(_ task: TaskItem) {
        self.task = task
        let body = AppFont.native(.body)
        mark.configure(task, model: AppModel.shared)
        bar.color = TaskRowCell.priorityBar(task.priority)
        folder.isHidden = !task.isProject
        folder.image = .symbol("folder", body, label: L("Project"))
        folder.contentTintColor = .secondaryLabelColor

        title.font = body
        title.textColor = task.done != nil ? .secondaryLabelColor : .labelColor
        title.isEditable = !locked
        title.isSelectable = true
        if !editing(title), title.string != task.title { title.string = task.title }

        notes.baseFont = body
        notes.isEditable = !locked
        if !editing(notes), notes.string != task.notes { notes.setText(task.notes) }
        placeholder.font = body
        placeholder.isHidden = !notes.string.isEmpty
        needsLayout = true
    }

    private func editing(_ view: NSTextView) -> Bool { window?.firstResponder === view }

    // MARK: Keyboard

    /// The caret goes after the title, the way Return and a double click open a card (R38).
    func focusTitle() {
        guard let window, !locked else { return }
        window.makeFirstResponder(title)
        title.setSelectedRange(NSRange(location: title.string.utf16.count, length: 0))
    }

    private func focusNotes() {
        guard let window, !locked else { return }
        window.makeFirstResponder(notes)
        notes.setSelectedRange(NSRange(location: notes.string.utf16.count, length: 0))
    }

    /// Esc: the card closes and the list has the keyboard again, with the row selected (R44).
    private func close() {
        commit(leaving: true)
        AppModel.shared.closeCard(task.id)
    }

    /// Clicks on the card itself are the card's: they neither select its row again nor close it with a double click.
    override func mouseDown(with event: NSEvent) {}

    // MARK: Saving

    private func commit(leaving: Bool) {
        commitTitle(leaving: leaving)
        commitNotes()
    }

    /// Saves the title. An emptied title goes back to what it was only when the field is left:
    /// the app stepping back for a moment does not undo what is being typed.
    private func commitTitle(leaving: Bool = true) {
        guard !locked else { return }
        let value = title.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != task.title else { return }
        if value.isEmpty {
            if leaving { title.string = task.title }
            return
        }
        let id = task.id
        AppModel.shared.perform { try $0.setTitle(id: id, title: value) }
    }

    private func commitNotes() {
        guard !locked, notes.string != task.notes else { return }
        let id = task.id
        let text = notes.string
        AppModel.shared.perform { try $0.setNotes(id: id, notes: text) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A card closed by a click elsewhere: what was typed is saved once the table is done with its rows.
        if window == nil { DispatchQueue.main.async { self.commit(leaving: true) } }
    }

    // MARK: Text

    func textDidChange(_ notification: Notification) {
        if notification.object as AnyObject === title, title.string.contains(where: \.isNewline) {
            // Pasted text of several lines becomes one line: a title has no line breaks.
            let range = title.selectedRange()
            title.string = title.string.split(whereSeparator: \.isNewline).joined(separator: " ")
            title.setSelectedRange(NSRange(location: min(range.location, title.string.utf16.count), length: 0))
        }
        placeholder.isHidden = !notes.string.isEmpty
        needsLayout = true
        onHeightChange()
    }

    func textDidEndEditing(_ notification: Notification) {
        if notification.object as AnyObject === title { commitTitle() } else { commitNotes() }
    }

    func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard view === notes else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        case #selector(NSResponder.insertNewline(_:)) where !AppModel.shared.returnAddsLine:
            close()
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
             #selector(NSResponder.insertLineBreak(_:)):
            return notes.continueList()
        default:
            return false
        }
    }

    // MARK: Layout

    private static func textHeight(_ view: NSTextView, width: CGFloat, font: NSFont) -> CGFloat {
        guard let container = view.textContainer, let layout = view.layoutManager else { return 0 }
        container.containerSize = NSSize(width: max(width, 1), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return max(ceil(layout.usedRect(for: container).height), TaskTableMetrics.lineHeight(font))
    }

    private struct Frames {
        var outline = NSRect.zero, mark = NSRect.zero, bar = NSRect.zero, folder = NSRect.zero
        var title = NSRect.zero, notes = NSRect.zero
        var height: CGFloat = 0
    }

    /// Where everything goes at a width; from the top, in a flipped sense, turned over at the end.
    private func frames(width: CGFloat) -> Frames {
        var frames = Frames()
        let body = AppFont.native(.body)
        let line = TaskTableMetrics.lineHeight(body)
        let content = Self.margin + Self.padding.left
        let contentWidth = max(width - 2 * content, 1)
        // The row of the task inside the card: the mark at the first line of the title (R73).
        var x = content + 6
        let headerTop = Self.margin + Self.padding.top + 6
        let markSize = mark.fittingSize
        frames.mark = NSRect(x: x, y: headerTop + (line - markSize.height) / 2, width: markSize.width, height: markSize.height)
        x += markSize.width + 8
        frames.bar = NSRect(x: x, y: headerTop + (line - 16) / 2, width: 3, height: 16)
        x += 3 + 8
        if !folder.isHidden {
            let size = folder.image?.size ?? .zero
            frames.folder = NSRect(x: x, y: headerTop + (line - size.height) / 2, width: size.width, height: size.height)
            x += size.width + 8
        }
        let titleWidth = max(content + contentWidth - 6 - x, 1)
        let titleHeight = Self.textHeight(title, width: titleWidth, font: body)
        frames.title = NSRect(x: x, y: headerTop, width: titleWidth, height: titleHeight)
        let notesTop = headerTop + titleHeight + 6 + 6
        let notesX = content + Self.notesIndent
        let notesWidth = max(content + contentWidth - notesX, 1)
        let notesHeight = Self.textHeight(notes, width: notesWidth, font: body)
        frames.notes = NSRect(x: notesX, y: notesTop, width: notesWidth, height: notesHeight)
        let bottom = notesTop + notesHeight + Self.padding.bottom
        frames.outline = NSRect(x: Self.margin, y: Self.margin, width: width - 2 * Self.margin, height: bottom - Self.margin)
        frames.height = bottom + Self.margin
        return frames
    }

    /// The height of the row the card needs at the width of the table.
    func height(width: CGFloat) -> CGFloat { ceil(frames(width: width).height) }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let frames = frames(width: bounds.width)
        outline.frame = frames.outline
        mark.frame = frames.mark
        bar.frame = frames.bar
        folder.frame = frames.folder
        title.frame = frames.title
        notes.frame = frames.notes
        placeholder.frame = NSRect(origin: frames.notes.origin, size: NSSize(width: frames.notes.width, height: TaskTableMetrics.lineHeight(AppFont.native(.body))))
    }
}

/// The outline that sets an open task apart from the rows around it.
final class CardOutline: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.10
        layer?.shadowRadius = 12
        layer?.shadowOffset = NSSize(width: 0, height: -4)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        // Barely there in the light appearance; in the dark one it is what tells the card from the window.
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
    }
}
