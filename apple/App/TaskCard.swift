import AppKit
import UniformTypeIdentifiers

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

/// The open card of a task in the task table (#308): the row of the task with its title to edit, the note, the row of
/// fields (R94) and the files (R54, R86). The card is drawn apart from the rows by its outline; it keeps what is being
/// typed while the table draws it again, and saves the title and the note when they lose the keyboard, when the card
/// closes and when the app quits or steps back (R38, R44, R73, R83).
@MainActor
final class TaskCard: NSView, NSTextViewDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("card")

    /// Space around the outline, and inside it around the content (the list before it had the same).
    private static let margin: CGFloat = 8
    private static let padding = NSEdgeInsets(top: 10, left: 10, bottom: 14, right: 10)
    /// The note, the fields and the files start under the title, past the mark and the bar.
    private static let indent: CGFloat = 34

    private(set) var task: TaskItem
    /// The height changed with the text, the fields or the files: the table learns it.
    var onHeightChange: () -> Void = {}

    private let outline = CardOutline()
    private let mark = TaskMarkButton()
    private let bar = FillView()
    private let folder = NSImageView()
    private let title = CardTitleView()
    private let notes = NoteTextView()
    private let placeholder = NSTextField(labelWithString: L("Notes"))
    private let chipsView = CardChipsView()
    private let filesView = CardFilesView()
    private let subtasksView = CardSubtasksView()
    /// R30, R31: the card of a task of an open project stands to the right, under the project.
    var depth = 0 {
        didSet { if depth != oldValue { needsLayout = true } }
    }
    private var lines: CardLines?
    private var observers: [NSObjectProtocol] = []

    private var model: AppModel { AppModel.shared }
    private var locked: Bool { task.deleted || task.isLog }

    init(task: TaskItem, lines: CardLines?) {
        self.task = task
        self.lines = lines
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
        // The note is changed by the click first; it is saved right after it.
        notes.onToggle = { [weak self] in DispatchQueue.main.async { self?.commitNotes() } }
        placeholder.textColor = .tertiaryLabelColor
        addSubview(placeholder)
        addSubview(notes)
        addSubview(chipsView)
        addSubview(filesView)
        addSubview(subtasksView)
        // R19: files dropped on the card are attached to the task.
        registerForDraggedTypes([.fileURL])

        // R83: quitting does not take the keyboard from the title or the note, and neither does another app coming forward.
        for name in [NSApplication.willTerminateNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.commit(leaving: false) }
            })
        }
        #if DEBUG
        observers.append(NotificationCenter.default.addObserver(forName: DebugScript.showFile, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.model.selection == self.task.id, let index = note.object as? Int, self.attachments.indices.contains(index) else { return }
                self.open(self.attachments[index])
            }
        })
        #endif
        title.string = task.title
        notes.setText(task.notes)
        attachments = (try? model.store?.attachments(taskId: task.id)) ?? []
        configure(task, lines: lines)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Takes the new state of the task and of its subtasks; what is being typed stays.
    func configure(_ task: TaskItem, lines: CardLines?) {
        self.task = task
        self.lines = lines
        subtasksView.configure(task, lines ?? CardLines(subtasks: [], shown: false, selected: [], renaming: nil))
        let body = AppFont.native(.body)
        mark.configure(task, model: model)
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
        reloadFiles()
        showChips()
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
        // Esc with a popover open is for the popover (R62).
        if let popover, popover.isShown { return popover.close() }
        commit(leaving: true)
        model.closeCard(task.id)
    }

    /// Clicks on the card itself are the card's: they neither select its row again nor close it with a double click.
    override func mouseDown(with event: NSEvent) {}

    /// ⌘S, ⌘D and ⇧⌘R open the start, the due date and the repeat of the selected card (R39); ⌘V with files or an image
    /// attaches them, with text it pastes as usual.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard event.type == .keyDown, !locked, model.selection == task.id, model.draft == nil else { return super.performKeyEquivalent(with: event) }
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (flags, key) {
        case ([.command], "s"): openChip(.start)
        case ([.command], "d"): openChip(.due)
        case ([.command, .shift], "r"): openChip(.repeat)
        case ([.command], "v"):
            let pasted = IncomingFiles.pasted()
            guard !pasted.isEmpty else { return super.performKeyEquivalent(with: event) }
            attach(pasted)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    // MARK: Fields (R62, R94)

    private var chips: [CardChip: ChipButton] = [:]
    private var popover: CardPopover?
    private let menus = ChoiceMenu()

    /// Where the chips stood when a popover opened: a chip does not change sides under its own popover.
    private var held: (left: [CardChip], right: [CardChip])?

    private var sides: (left: [CardChip], right: [CardChip]) {
        if let held { return held }
        let dated: [(CardChip, Bool)] = [
            (.start, task.start != nil), (.due, task.due != nil), (.repeat, task.repeat != nil),
            (.remind, task.remind != nil), (.priority, task.priority != .none),
        ]
        return (
            dated.filter(\.1).map(\.0) + task.tags.map(CardChip.tag),
            dated.filter { !$0.1 }.map(\.0) + [.newTag] + (model.showsSubtasks(task) ? [] : [.subtask]) + [.file])
    }

    private func chipButton(_ chip: CardChip) -> ChipButton {
        if let found = chips[chip] { return found }
        let button = ChipButton(chip)
        button.onStep = { [weak self] by in self?.step(from: chip, by: by) }
        button.onOpen = { [weak self] in self?.openChip(chip) }
        button.onCancel = { [weak self] in self?.close() }
        button.onFocus = { [weak self] held in self?.chipFocus(chip, held: held) }
        chips[chip] = button
        return button
    }

    private func showChips() {
        let (left, right) = sides
        let shown = Set(left + right)
        chips = chips.filter { shown.contains($0.key) }
        for chip in left { describe(chipButton(chip), set: true) }
        for chip in right { describe(chipButton(chip), set: false) }
        chipsView.set(left: left.map(chipButton), right: right.map(chipButton))
    }

    private func describe(_ button: ChipButton, set: Bool) {
        let accent = NSColor.controlAccentColor
        button.plain = !set
        button.isEnabled = !locked
        switch button.chip {
        case .start:
            (button.symbol, button.text, button.tint) = ("calendar.badge.clock", task.start.map { L("Start: ") + Moment.label($0).lowercased() } ?? "", accent)
            button.toolTip = L("Start date (⌘S)")
        case .due:
            let late = task.due.map { Moment.isOverdue($0) && task.done == nil } ?? false
            (button.symbol, button.text, button.tint) = ("calendar", task.due.map { L("Due: ") + Moment.label($0).lowercased() } ?? "", late ? .systemRed : accent)
            button.toolTip = L("Due date (⌘D)")
        case .repeat:
            (button.symbol, button.text, button.tint) = ("repeat", task.repeat?.summary ?? "", accent)
            button.toolTip = L("Repeat (⇧⌘R)")
        case .remind:
            (button.symbol, button.text, button.tint) = ("bell", task.remind.map(Moment.label) ?? "", accent)
            button.toolTip = L("Reminder")
        case .priority:
            (button.symbol, button.text, button.tint) = ("flag", task.priority == .none ? "" : task.priority.title, task.priority == .none ? .secondaryLabelColor : .systemOrange)
            button.toolTip = L("Priority")
        case .tag(let tag):
            (button.symbol, button.text, button.tint) = (nil, "#\(tag) ×", .secondaryLabelColor)
            button.toolTip = L("Remove tag")
        case .newTag:
            (button.symbol, button.text) = ("number", "")
            button.toolTip = L("Tag")
        case .subtask:
            (button.symbol, button.text) = ("checklist", "")
            button.toolTip = L("Subtask")
        case .file:
            (button.symbol, button.text) = ("paperclip", "")
            button.toolTip = L("File or image")
        case .list:
            break
        }
        button.refresh()
    }

    /// Tab and ⇧Tab from a chip (R62): ⇧Tab on the first one goes back to the note, Tab on the last one to the title.
    private func step(from chip: CardChip, by: Int) {
        let stops = chipsView.stops
        guard let index = stops.firstIndex(where: { $0.chip == chip }) else { return }
        if index + by < 0 { return focusNotes() }
        if index + by >= stops.count { return focusTitle() }
        window?.makeFirstResponder(stops[index + by])
    }

    private func chipFocus(_ chip: CardChip, held: Bool) {
        if held { Keyboard.cards.insert(task.id) } else { Keyboard.cards.remove(task.id) }
        #if DEBUG
        DebugScript.chip = held ? "\(chip)" : (DebugScript.chip == "\(chip)" ? nil : DebugScript.chip)
        #endif
    }

    /// What a click on a chip, Space and Return on it, and the keys of R39 do.
    private func openChip(_ chip: CardChip) {
        guard !locked else { return }
        let id = task.id
        switch chip {
        case .start:
            showPopover(chip, DatePopoverView(title: L("Start: hidden from Today until"), value: task.start) { [model] value in
                model.perform { try $0.setStart(id: id, start: value) }
            })
        case .due:
            showPopover(chip, DatePopoverView(title: L("Due"), value: task.due) { [model] value in
                model.perform { try $0.setDue(id: id, due: value) }
            })
        case .remind:
            showPopover(chip, DatePopoverView(title: L("Remind me"), value: task.remind, timeRequired: true) { [model] value in
                model.perform { try $0.setRemind(id: id, remind: value) }
            })
        case .repeat:
            showPopover(chip, RepeatPopoverView(value: task.repeat) { [model] rule in
                model.perform { try $0.setRepeat(id: id, repeat: rule) }
            })
        case .newTag:
            showPopover(chip, TagPopoverView(known: model.tags.map(\.name).filter { !task.tags.contains($0) }) { [model] tag in
                model.perform { try $0.addTag(id: id, tag: tag) }
            })
        case .priority:
            let choices = Priority.all.map { priority in
                MenuChoice(title: priority.title, on: task.priority == priority) { [model] in model.perform { try $0.setPriority(id: id, priority: priority) } }
            }
            menus.show(choices, under: chipButton(.priority))
        case .tag(let tag):
            // The keyboard goes to the chip that takes the place of the removed one (R62).
            let had = window?.firstResponder === chips[chip]
            let index = chipsView.stops.firstIndex { $0.chip == chip } ?? 0
            model.perform { try $0.removeTag(id: id, tag: tag) }
            guard had, let fresh = model.row(id) else { return }
            configure(fresh, lines: lines)
            let now = chipsView.stops
            if !now.isEmpty { window?.makeFirstResponder(now[min(index, now.count - 1)]) }
        case .subtask:
            // The field of the first subtask opens and takes the keyboard (R38).
            model.showSubtasks(id)
            DispatchQueue.main.async { [weak self] in self?.subtasksView.focusField() }
        case .file:
            chooseFiles()
        case .list:
            break
        }
    }

    private func showPopover(_ chip: CardChip, _ view: NSView) {
        popover?.close()
        held = sides
        let shown = CardPopover(view)
        let dismiss: () -> Void = { [weak shown] in shown?.close() }
        (view as? DatePopoverView)?.dismiss = dismiss
        (view as? RepeatPopoverView)?.dismiss = dismiss
        (view as? TagPopoverView)?.dismiss = dismiss
        shown.onClose = { [weak self] in
            guard let self else { return }
            self.held = nil
            self.popover = nil
            #if DEBUG
            DebugScript.popover = nil
            #endif
            self.showChips()
            self.needsLayout = true
            self.onHeightChange()
        }
        popover = shown
        #if DEBUG
        DebugScript.popover = "\(chip)"
        #endif
        shown.show(under: chipButton(chip))
    }

    // MARK: Files (R19, R54, R76, R86, R91)

    private var attachments: [Attachment] = []
    /// Files being downloaded on request, and those the last request did not get (R76).
    private var fetching: Set<String> = []
    private var fetchFailed: Set<String> = []
    private var fileRows: [String: FileRowView] = [:]

    /// Reads the files of the task again: after a change and when the content of files has arrived (R76).
    func reloadFiles() {
        attachments = (try? model.store?.attachments(taskId: task.id)) ?? []
        let ids = Set(attachments.map(\.id))
        fileRows = fileRows.filter { ids.contains($0.key) }
        let rows = attachments.map { file -> FileRowView in
            let row = fileRows[file.id] ?? makeRow(file)
            fileRows[file.id] = row
            row.configure(file, fetching: isFetching(file), failed: fetchFailed.contains(file.id), locked: locked)
            return row
        }
        filesView.set(rows)
        needsLayout = true
    }

    private func makeRow(_ file: Attachment) -> FileRowView {
        let actions = FileActions(
            open: { [weak self] in self?.open($0) },
            remove: { [weak self] file in
                self?.model.perform { try $0.removeAttachment(id: file.id) }
                self?.reloadFiles()
                self?.onHeightChange()
            },
            choices: { [weak self] in self?.fileChoices($0) ?? [] },
            cancel: { [weak self] in self?.close() })
        let row = FileRowView(file: file, actions: actions)
        row.siblings = { [weak self] in self?.attachments ?? [] }
        row.onFocus = { [weak self] held in
            guard let self else { return }
            if held { Keyboard.cards.insert(self.task.id) } else { Keyboard.cards.remove(self.task.id) }
            #if DEBUG
            DebugScript.file = held ? file.name : nil
            #endif
        }
        return row
    }

    /// A file that is being downloaded: asked for by a click, or awaited by "Save All…" (R76, R91).
    private func isFetching(_ file: Attachment) -> Bool {
        fetching.contains(file.id) || (file.localPath == nil && model.savingAttachments.contains(task.id))
    }

    /// The actions of a file that is on this device: the same under its menu button and its right click (R54, R86).
    private func fileChoices(_ file: Attachment) -> [MenuChoice] {
        let one = [
            MenuChoice(title: L("Quick Look")) { [weak self] in self?.open(file) },
            MenuChoice(title: L("Open in Default App")) { [model] in
                if let url = AttachmentFiles.named(file), !NSWorkspace.shared.open(url) {
                    model.store?.log(level: .error, source: "attachments", message: "the system did not open a file in its default app")
                }
            },
            MenuChoice(title: L("Save As…")) { [model] in
                AttachmentFiles.saveAs(file) { reason in
                    model.alertIsError = true
                    model.alert = reason
                }
            },
        ]
        // R91: with more than one file, all of them go into a folder in one action.
        let id = task.id
        return attachments.count > 1 ? one + [MenuChoice(title: L("Save All…")) { [model] in model.saveAllAttachments(of: id) }] : one
    }

    private func open(_ file: Attachment) {
        if file.localPath == nil { fetch(file) } else { fileRows[file.id]?.show(among: attachments) }
    }

    /// R76: a file that has not arrived is downloaded ahead of the others and shown.
    private func fetch(_ file: Attachment) {
        guard let store = model.store, !isFetching(file) else { return }
        let id = file.id
        fetching.insert(id)
        fetchFailed.remove(id)
        reloadFiles()
        _Concurrency.Task { [weak self] in
            let arrived = await _Concurrency.Task.detached(priority: .userInitiated) {
                (try? store.fetchAttachment(id: id))?.localPath != nil
            }.value
            guard let self else { return }
            self.fetching.remove(id)
            guard arrived else {
                self.fetchFailed.insert(id)
                return self.reloadFiles()
            }
            self.model.attachmentsMoved(arrived: true)
            self.reloadFiles()
            if let got = self.attachments.first(where: { $0.id == id }) { self.open(got) }
        }
    }

    private func attach(_ urls: [URL]) {
        // A file of a card dragged out and dropped back is not a new attachment.
        model.attach(urls.filter { !AttachmentFiles.isCopy($0) }, to: task.id)
        reloadFiles()
        onHeightChange()
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        attach(panel.urls)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        locked || droppedFiles(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFiles(sender)
        guard !locked, !urls.isEmpty else { return false }
        attach(urls)
        return true
    }

    private func droppedFiles(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

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
        model.perform { try $0.setTitle(id: id, title: value) }
    }

    private func commitNotes() {
        guard !locked, notes.string != task.notes else { return }
        let id = task.id
        let text = notes.string
        model.perform { try $0.setNotes(id: id, notes: text) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        // A card closed by a click elsewhere: what was typed is saved once the table is done with its rows.
        DispatchQueue.main.async { self.commit(leaving: true) }
        popover?.close()
        Keyboard.cards.remove(task.id)
        #if DEBUG
        DebugScript.chip = nil
        DebugScript.file = nil
        #endif
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
        case #selector(NSResponder.insertNewline(_:)) where !model.returnAddsLine:
            close()
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
             #selector(NSResponder.insertLineBreak(_:)):
            return notes.continueList()
        // R62: Tab goes on to the first chip; ⌥Tab still types a tab.
        case #selector(NSResponder.insertTab(_:)):
            guard let first = chipsView.stops.first else { return false }
            window?.makeFirstResponder(first)
            return true
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
        var title = NSRect.zero, notes = NSRect.zero, chips = NSRect.zero, files = NSRect.zero, subtasks = NSRect.zero
        var height: CGFloat = 0
    }

    /// Where everything goes at a width, from the top.
    private func frames(width: CGFloat) -> Frames {
        var frames = Frames()
        let body = AppFont.native(.body)
        let line = TaskTableMetrics.lineHeight(body)
        let shift = CGFloat(depth) * TaskTableMetrics.depthIndent
        let content = shift + Self.margin + Self.padding.left
        let contentWidth = max(width - shift - 2 * (Self.margin + Self.padding.left), 1)
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
        // Under the title: the note, the fields and the files, ten points apart.
        let left = content + Self.indent
        let innerWidth = max(content + contentWidth - left, 1)
        var y = headerTop + titleHeight + 6 + 6
        let notesHeight = Self.textHeight(notes, width: innerWidth, font: body)
        frames.notes = NSRect(x: left, y: y, width: innerWidth, height: notesHeight)
        y += notesHeight + 10
        let chipsHeight = chipsView.height(width: innerWidth)
        frames.chips = NSRect(x: left, y: y, width: innerWidth, height: chipsHeight)
        y += chipsHeight
        if !filesView.rows.isEmpty {
            y += 10
            frames.files = NSRect(x: left, y: y, width: innerWidth, height: filesView.height)
            y += filesView.height
        }
        if !subtasksView.isEmpty {
            y += 6
            frames.subtasks = NSRect(x: left, y: y, width: innerWidth, height: subtasksView.height)
            y += subtasksView.height
        }
        let bottom = y + Self.padding.bottom
        frames.outline = NSRect(x: shift + Self.margin, y: Self.margin, width: width - shift - 2 * Self.margin, height: bottom - Self.margin)
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
        chipsView.frame = frames.chips
        filesView.frame = frames.files
        subtasksView.frame = frames.subtasks
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
