import AppKit
import SwiftUI

/// A task that is being typed and does not exist yet.
struct TaskDraft: Equatable {
    var title = ""
    var notes = ""
    /// The note as it came from the clipboard (R58); nil when it was typed.
    var pastedNotes: String?
    var start: String?
    /// The due date chosen in the card; nil while the title or the list decides (R75).
    var due: String?
    /// The date was taken away in the card: the task gets none from its list.
    var dueRemoved = false
    var `repeat`: Repeat?
    var priority = Priority.none
    /// The priority was chosen in the card, "none" included: the default of
    /// the list no longer applies.
    var priorityChosen = false
    var tags: [String] = []
    var listId = "inbox"
    /// Set when the task is typed inside a project or the project is chosen in the card (R129): it becomes a task of it.
    var parentId: String?
    /// Attached once the task exists.
    var files: [URL] = []
    /// The subtasks typed in the card (R113): they are created with the task, in this order.
    var subtasks: [String] = []
    /// What is in the field of the next subtask and has not been added.
    var subtaskText = ""
    /// The icon of subtasks was pressed: the field of the next subtask is on show.
    var subtasksShown = false
    /// R130: the task the new one goes right under; none puts it first in its list.
    var after: String?

    var isBlank: Bool { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Return in the field of the next subtask: what is typed there becomes a line, an empty field adds none (R113).
    mutating func addSubtask() {
        let title = subtaskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        subtasks.append(title)
        subtaskText = ""
    }

    /// The subtasks the saved task gets: the lines, then what was left in the field. A line emptied in the card is not one.
    var typedSubtasks: [String] {
        (subtasks + [subtaskText]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// The card of a new task on AppKit (#308), the same in the list of the main window (R37), in the quick-entry panel and
/// in the menu bar window (R82, R114): every field can be filled before the task is created. Return in the title and
/// ⌘Return anywhere save; Esc saves in the list (R37) and throws the card away in the panel and the menu bar window (R114).
@MainActor
final class DraftCard: NSView, NSTextViewDelegate, NSTextFieldDelegate {
    /// The quick-entry panel: the card pads itself and ends with a strip that holds the list and the two buttons (R82).
    let footer: Bool
    /// Where Esc goes: the list keeps the task (R37), the panel and the menu bar window throw it away (R114).
    let escSaves: Bool
    private(set) var draft: TaskDraft
    /// The draft changed in the card.
    var onChange: (TaskDraft) -> Void = { _ in }
    /// The card is done with, saved or not.
    var onClose: () -> Void = {}
    /// The height changed.
    var onResize: () -> Void = {}

    private let outline = CardOutline()
    private let mark = NSImageView()
    private let title = CardTitleView()
    private let titlePlaceholder = NSTextField(labelWithString: L("New task"))
    private let parsed = CardChipsView()
    private let notes = NoteTextView()
    private let notesPlaceholder = NSTextField(labelWithString: L("Notes"))
    private let pasteBox = PasteBlock()
    private let pasteRemove = NSButton()
    private let chipsView = CardChipsView()
    private let subtaskViews = FlippedView()
    private var subtaskLines: [(mark: NSImageView, field: NSTextField, remove: NSButton)] = []
    private let subtaskPlus = NSImageView()
    private let subtaskField = NSTextField()
    private let filesView = FlippedView()
    private var fileLines: [(icon: NSImageView, name: NSTextField, remove: NSButton)] = []
    private let strip = FillView()
    private let stripLine = FillView()
    private let stripList = NSButton()
    // The grey of secondary text, at a little more than half of it.
    private let cancelButton = StripButton(title: L("Cancel"), fill: NSColor.labelColor.withAlphaComponent(0.275))
    private let saveButton = StripButton(title: L("Save"), fill: .controlAccentColor)
    /// The note taken from the clipboard was opened for editing: it is drawn as an ordinary note from then on.
    private var pasteOpen = false

    private var model: AppModel { AppModel.shared }

    init(draft: TaskDraft, footer: Bool, escSaves: Bool) {
        self.draft = draft
        self.footer = footer
        self.escSaves = escSaves
        super.init(frame: .zero)
        // The outline reaches past the edges of the row.
        clipsToBounds = false
        outline.isHidden = footer
        addSubview(outline)
        mark.contentTintColor = .tertiaryLabelColor
        addSubview(mark)

        title.delegate = self
        title.drawsBackground = false
        title.isRichText = false
        title.allowsUndo = true
        title.textContainerInset = .zero
        // The text starts two points in, as in a label: the title of a row and its card stand at one place.
        title.textContainer?.lineFragmentPadding = 2
        title.textContainer?.widthTracksTextView = true
        title.isVerticallyResizable = false
        title.isHorizontallyResizable = false
        title.setAccessibilityLabel(L("New task"))
        title.onReturn = { [weak self] in self?.save() }
        title.onEscape = { [weak self] in self?.cancel() }
        title.onTab = { [weak self] in self?.focusNotes() }
        titlePlaceholder.textColor = .placeholderTextColor
        addSubview(titlePlaceholder)
        addSubview(title)
        addSubview(parsed)

        notes.prepare()
        notes.delegate = self
        notes.allowsUndo = true
        notes.drawsBackground = false
        notes.textContainerInset = .zero
        notes.textContainer?.lineFragmentPadding = 2
        notes.textContainer?.widthTracksTextView = true
        notes.isVerticallyResizable = false
        notes.isHorizontallyResizable = false
        notesPlaceholder.textColor = .tertiaryLabelColor
        addSubview(notesPlaceholder)
        addSubview(notes)
        pasteBox.onClick = { [weak self] in
            self?.pasteOpen = true
            self?.refresh()
            self?.focusNotes()
        }
        addSubview(pasteBox)
        pasteRemove.isBordered = false
        pasteRemove.target = self
        pasteRemove.action = #selector(removePasted)
        pasteRemove.toolTip = L("Remove the text taken from the clipboard")
        pasteRemove.contentTintColor = .tertiaryLabelColor
        addSubview(pasteRemove)

        addSubview(chipsView)
        addSubview(subtaskViews)
        subtaskPlus.contentTintColor = .tertiaryLabelColor
        subtaskField.isBordered = false
        subtaskField.drawsBackground = false
        subtaskField.focusRingType = .none
        subtaskField.placeholderString = L("Subtask")
        subtaskField.delegate = self
        subtaskViews.addSubview(subtaskPlus)
        subtaskViews.addSubview(subtaskField)
        addSubview(filesView)

        strip.color = NSColor.labelColor.withAlphaComponent(0.05)
        stripLine.color = .separatorColor
        stripList.isBordered = false
        stripList.target = self
        stripList.action = #selector(openListMenu)
        stripList.toolTip = L("List")
        cancelButton.target = self
        cancelButton.action = #selector(discard)
        saveButton.target = self
        saveButton.action = #selector(save)
        for view in [strip, stripLine, stripList, cancelButton, saveButton] as [NSView] {
            view.isHidden = !footer
            addSubview(view)
        }
        registerForDraggedTypes([.fileURL])
        title.string = draft.title
        notes.setText(draft.notes)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Takes a draft changed outside the card; what is being typed stays.
    func sync(_ new: TaskDraft) {
        guard new != draft else { return }
        draft = new
        if !editing(title), title.string != draft.title { title.string = draft.title }
        if !editing(notes), notes.string != draft.notes { notes.setText(draft.notes) }
        refresh()
    }

    private func editing(_ view: NSView) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === view { return true }
        return ((responder as? NSText)?.delegate as? NSView) === view
    }

    private func change(_ edit: (inout TaskDraft) -> Void) {
        edit(&draft)
        onChange(draft)
        refresh()
    }

    // MARK: Content

    private var shownDue: String? { model.shownDue(draft) }
    private var shownPriority: Priority { model.shownPriority(draft) }

    /// The note came from the clipboard and has not been touched or opened (R58).
    private var pasteShown: Bool {
        guard !pasteOpen, let pasted = draft.pastedNotes else { return false }
        return !pasted.isEmpty && draft.notes == pasted
    }

    private func refresh() {
        let body = AppFont.native(.body)
        // A task that does not exist yet has nothing to complete: the mark only says what the card is.
        mark.image = .symbol("square", body)
        title.font = body
        titlePlaceholder.font = body
        titlePlaceholder.isHidden = !title.string.isEmpty
        notes.baseFont = body
        notesPlaceholder.font = body
        notesPlaceholder.isHidden = !notes.string.isEmpty || pasteShown
        notes.isHidden = pasteShown
        pasteBox.isHidden = !pasteShown
        pasteBox.text = draft.notes
        let pastedHere = draft.pastedNotes.map { draft.notes == $0 } ?? false
        pasteRemove.isHidden = !pastedHere
        pasteRemove.image = .symbol("xmark.circle.fill", body)
        showParsed()
        showChips()
        showSubtasks()
        showFiles()
        showStrip()
        needsLayout = true
        onResize()
    }

    /// What the quick-entry parser recognised in the title (R41).
    private func showParsed() {
        guard model.parseQuickText, !draft.title.isEmpty, let parse = model.store?.parseQuick(text: draft.title) else {
            return parsed.set(left: [], right: [])
        }
        var chips: [ChipButton] = []
        func chip(_ symbol: String?, _ text: String, _ tint: NSColor = .secondaryLabelColor) {
            let button = ChipButton(.list)
            (button.symbol, button.text, button.tint) = (symbol, text, tint)
            button.isEnabled = false
            button.refresh()
            chips.append(button)
        }
        if let due = parse.due { chip("calendar", Moment.label(due)) }
        if parse.priority != .none { chip(nil, parse.priority.marks, .systemOrange) }
        for tag in parse.tags { chip(nil, "#\(tag)") }
        if let list = parse.listName { chip("list.bullet", list) }
        parsed.set(left: chips, right: [])
    }

    // MARK: Fields (R62, R82)

    private var chips: [CardChip: ChipButton] = [:]
    private var popover: CardPopover?
    private let menus = ChoiceMenu()
    private var held: (left: [CardChip], right: [CardChip])?

    private var sides: (left: [CardChip], right: [CardChip]) {
        if let held { return held }
        let dated: [(CardChip, Bool)] = [
            (.start, draft.start != nil), (.due, shownDue != nil), (.repeat, draft.repeat != nil), (.priority, shownPriority != .none),
        ]
        return (
            dated.filter(\.1).map(\.0) + draft.tags.map(CardChip.tag) + (footer ? [] : [.list]),
            dated.filter { !$0.1 }.map(\.0) + [.newTag] + (draft.subtasksShown ? [] : [.subtask]) + [.file])
    }

    /// The chips in the order Tab walks them in (R62); in the panel the list in the strip is the last.
    private var stops: [NSView] { chipsView.stops + (footer ? [stripList] : []) }

    private func chipButton(_ chip: CardChip) -> ChipButton {
        if let found = chips[chip] { return found }
        let button = ChipButton(chip)
        button.onStep = { [weak self] by in self?.step(from: button, by: by) }
        button.onOpen = { [weak self] in self?.openChip(chip) }
        button.onCancel = { [weak self] in self?.cancel() }
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

    private var listName: (name: String, symbol: String, project: Bool) {
        let list = model.list(draft.listId)
        let project = draft.parentId.flatMap { id in model.projects.first { $0.id == id } }
        return (project?.title ?? list.map(model.listName) ?? L("Inbox"), project == nil ? list?.symbol ?? "tray" : "folder", project != nil)
    }

    private func describe(_ button: ChipButton, set: Bool) {
        let accent = NSColor.controlAccentColor
        button.plain = !set
        switch button.chip {
        case .start:
            (button.symbol, button.text, button.tint) = ("calendar.badge.clock", draft.start.map { L("Start: ") + Moment.label($0).lowercased() } ?? "", accent)
            button.toolTip = L("Start date (⌘S)")
        case .due:
            (button.symbol, button.text, button.tint) = ("calendar", shownDue.map { L("Due: ") + Moment.label($0).lowercased() } ?? "", accent)
            button.toolTip = L("Due date (⌘D)")
        case .repeat:
            (button.symbol, button.text, button.tint) = ("repeat", draft.repeat?.summary ?? "", accent)
            button.toolTip = L("Repeat (⇧⌘R)")
        case .priority:
            let priority = shownPriority
            (button.symbol, button.text, button.tint) = ("flag", priority == .none ? "" : priority.title, priority == .none ? .secondaryLabelColor : .systemOrange)
            button.toolTip = L("Priority")
        case .tag(let tag):
            (button.symbol, button.text, button.tint) = (nil, "#\(tag) ×", .secondaryLabelColor)
            button.toolTip = L("Remove tag")
        case .newTag:
            (button.symbol, button.text) = ("number", "")
            button.toolTip = L("Tag")
        case .list:
            let list = listName
            (button.symbol, button.text, button.tint) = (list.project ? "folder" : "list.bullet", list.name, .secondaryLabelColor)
            button.toolTip = L("List")
        case .subtask:
            (button.symbol, button.text) = ("checklist", "")
            button.toolTip = L("Subtask")
        case .file:
            (button.symbol, button.text) = ("paperclip", "")
            button.toolTip = L("File or image")
        case .remind:
            break
        }
        button.refresh()
    }

    private func step(from view: NSView, by: Int) {
        let all = stops
        guard let index = all.firstIndex(where: { $0 === view }) else { return }
        if index + by < 0 { return focusNotes() }
        if index + by >= all.count { return focusTitle() }
        window?.makeFirstResponder(all[index + by])
    }

    private func chipFocus(_ chip: CardChip, held: Bool) {
        if held { Keyboard.cards.insert("draft") } else { Keyboard.cards.remove("draft") }
        #if DEBUG
        DebugScript.chip = held ? "\(chip)" : (DebugScript.chip == "\(chip)" ? nil : DebugScript.chip)
        #endif
    }

    private func openChip(_ chip: CardChip) {
        switch chip {
        case .start:
            showPopover(chip, DatePopoverView(title: L("Start: hidden from Today until"), value: draft.start) { [weak self] value in
                self?.change { $0.start = value }
            })
        case .due:
            showPopover(chip, DatePopoverView(title: L("Due"), value: shownDue) { [weak self] value in
                self?.change {
                    $0.due = value
                    $0.dueRemoved = value == nil
                }
            })
        case .repeat:
            showPopover(chip, RepeatPopoverView(value: draft.repeat) { [weak self] rule in self?.change { $0.repeat = rule } })
        case .newTag:
            showPopover(chip, TagPopoverView(known: model.tags.map(\.name).filter { !draft.tags.contains($0) }) { [weak self] tag in
                let name = AppModel.cleanTag(tag)
                self?.change { if !name.isEmpty, !$0.tags.contains(name) { $0.tags.append(name) } }
            })
        case .priority:
            let choices = Priority.all.map { priority in
                MenuChoice(title: priority.title, on: shownPriority == priority) { [weak self] in
                    self?.change {
                        $0.priority = priority
                        $0.priorityChosen = true
                    }
                }
            }
            menus.show(choices, under: chipButton(.priority))
        case .tag(let tag):
            // The keyboard goes to the chip that takes the place of the removed one (R62).
            let had = window?.firstResponder === chips[chip]
            let index = chipsView.stops.firstIndex { $0.chip == chip } ?? 0
            change { $0.tags.removeAll { $0 == tag } }
            let now = chipsView.stops
            if had, !now.isEmpty { window?.makeFirstResponder(now[min(index, now.count - 1)]) }
        case .list:
            menus.show(listChoices, under: chipButton(.list))
        case .subtask:
            // R113: the field for the first subtask comes with the cursor in it.
            change { $0.subtasksShown = true }
            window?.makeFirstResponder(subtaskField)
        case .file:
            add(IncomingFiles.pick())
        case .remind:
            break
        }
    }

    /// The lists and, under them as a group of their own, the projects (R129).
    private var listChoices: [MenuChoice] {
        let lists = model.lists.filter { !$0.archived }.map { list in
            MenuChoice(title: model.listName(list), on: draft.parentId == nil && draft.listId == list.id) { [weak self] in
                self?.change {
                    $0.listId = list.id
                    $0.parentId = nil
                }
            }
        }
        guard !model.projects.isEmpty else { return lists }
        return lists + [.header(L("Projects"))] + model.projects.map { project in
            MenuChoice(title: project.title, on: draft.parentId == project.id) { [weak self] in
                self?.change {
                    $0.listId = project.listId
                    $0.parentId = project.id
                }
            }
        }
    }

    @objc private func openListMenu() { menus.show(listChoices, under: stripList) }

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
            self.refresh()
        }
        popover = shown
        #if DEBUG
        DebugScript.popover = "\(chip)"
        #endif
        shown.show(under: chipButton(chip))
    }

    // MARK: Subtasks (R113)

    private func showSubtasks() {
        let font = AppFont.native(.callout)
        while subtaskLines.count > draft.subtasks.count {
            let line = subtaskLines.removeLast()
            [line.mark, line.field, line.remove].forEach { $0.removeFromSuperview() }
        }
        while subtaskLines.count < draft.subtasks.count {
            let index = subtaskLines.count
            let mark = NSImageView()
            mark.contentTintColor = .tertiaryLabelColor
            let field = NSTextField()
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.placeholderString = L("Subtask")
            field.delegate = self
            field.tag = index
            let remove = NSButton()
            remove.isBordered = false
            remove.tag = index
            remove.target = self
            remove.action = #selector(removeSubtask(_:))
            remove.toolTip = L("Remove")
            remove.contentTintColor = .tertiaryLabelColor
            [mark, field, remove].forEach(subtaskViews.addSubview)
            subtaskLines.append((mark, field, remove))
        }
        for (index, line) in subtaskLines.enumerated() {
            line.mark.image = .symbol("square", font, weight: .light)
            line.field.font = font
            if !editing(line.field), line.field.stringValue != draft.subtasks[index] { line.field.stringValue = draft.subtasks[index] }
            line.remove.image = .symbol("xmark.circle.fill", font)
        }
        subtaskPlus.image = .symbol("plus.circle", font)
        subtaskField.font = font
        if !editing(subtaskField), subtaskField.stringValue != draft.subtaskText { subtaskField.stringValue = draft.subtaskText }
        subtaskViews.isHidden = !draft.subtasksShown
    }

    @objc private func removeSubtask(_ sender: NSButton) {
        change { if $0.subtasks.indices.contains(sender.tag) { $0.subtasks.remove(at: sender.tag) } }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === subtaskField {
            draft.subtaskText = field.stringValue
        } else if draft.subtasks.indices.contains(field.tag) {
            draft.subtasks[field.tag] = field.stringValue
        }
        onChange(draft)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Return in the field adds the line and leaves the cursor there for the next one; an empty field adds none.
            if control === subtaskField {
                change { $0.addSubtask() }
                subtaskField.stringValue = ""
            }
            window?.makeFirstResponder(subtaskField)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    // MARK: Files

    private func showFiles() {
        let font = AppFont.native(.callout)
        fileLines.forEach { [$0.icon, $0.name, $0.remove].forEach { $0.removeFromSuperview() } }
        fileLines = draft.files.enumerated().map { index, url in
            let icon = NSImageView(image: NSImage.symbol("paperclip", font) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            let name = NSTextField(labelWithString: url.lastPathComponent)
            name.font = font
            name.lineBreakMode = .byTruncatingMiddle
            let remove = NSButton()
            remove.isBordered = false
            remove.image = .symbol("xmark.circle.fill", font)
            remove.contentTintColor = .tertiaryLabelColor
            remove.tag = index
            remove.target = self
            remove.action = #selector(removeFile(_:))
            remove.toolTip = L("Remove attachment")
            [icon, name, remove].forEach(filesView.addSubview)
            return (icon, name, remove)
        }
    }

    @objc private func removeFile(_ sender: NSButton) {
        guard draft.files.indices.contains(sender.tag) else { return }
        let url = draft.files[sender.tag]
        change { $0.files.removeAll { $0 == url } }
        IncomingFiles.discard(url)
    }

    private func add(_ urls: [URL]) {
        change { draft in draft.files.append(contentsOf: urls.filter { !draft.files.contains($0) }) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { droppedFiles(sender).isEmpty ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFiles(sender)
        guard !urls.isEmpty else { return false }
        add(urls)
        return true
    }

    private func droppedFiles(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    // MARK: The strip of the panel (R82)

    private func showStrip() {
        guard footer else { return }
        let list = listName
        let font = AppFont.native(.callout).weighted(.semibold)
        let text = NSMutableAttributedString()
        if let image = NSImage.symbol(list.symbol, font) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: list.name))
        text.addAttributes([.font: font, .foregroundColor: NSColor.secondaryLabelColor], range: NSRange(location: 0, length: text.length))
        stripList.attributedTitle = text
        saveButton.isEnabled = !draft.isBlank
        cancelButton.needsDisplay = true
        saveButton.needsDisplay = true
    }

    // MARK: Keyboard and the ways out

    func focusTitle() {
        guard let window else { return }
        window.makeFirstResponder(title)
        title.setSelectedRange(NSRange(location: title.string.utf16.count, length: 0))
    }

    private func focusNotes() {
        guard let window else { return }
        if pasteShown {
            pasteOpen = true
            refresh()
        }
        window.makeFirstResponder(notes)
        notes.setSelectedRange(NSRange(location: notes.string.utf16.count, length: 0))
    }

    /// Return, ⌘Return and "Save": the task is created when it has a title.
    @objc func save() {
        if let popover, popover.isShown { popover.close() }
        draft.title = title.string
        draft.notes = notes.string
        let done = draft
        if done.isBlank {
            done.files.forEach(IncomingFiles.discard)
        } else {
            model.save(done)
        }
        finish()
    }

    /// Esc: in the list the card goes and its task is kept (R37); in the panel and the menu bar window what was typed
    /// is thrown away (R114). With a popover open Esc is for the popover (R62).
    private func cancel() {
        if let popover, popover.isShown { return popover.close() }
        if escSaves { save() } else { discard() }
    }

    /// Esc and "Cancel" of the panel: the card goes and nothing is created (R114).
    @objc func discard() {
        if let popover, popover.isShown { popover.close() }
        draft.files.forEach(IncomingFiles.discard)
        finish()
    }

    private func finish() {
        Keyboard.cards.remove("draft")
        #if DEBUG
        DebugScript.chip = nil
        #endif
        onClose()
    }

    /// The dates and the repeat are one key away from wherever the cursor is; ⌘Return saves from any field; ⌘V with
    /// files or an image attaches them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder.map(isInside) == true else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (flags, key, event.keyCode) {
        case ([.command], _, 36), ([.command], _, 76): save()
        case ([.command], "s", _): openChip(.start)
        case ([.command], "d", _): openChip(.due)
        case ([.command, .shift], "r", _): openChip(.repeat)
        case ([.command], "v", _):
            let pasted = IncomingFiles.pasted()
            guard !pasted.isEmpty else { return super.performKeyEquivalent(with: event) }
            add(pasted)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private func isInside(_ responder: NSResponder) -> Bool {
        guard let view = ((responder as? NSText)?.delegate as? NSView) ?? responder as? NSView else { return false }
        return view.isDescendant(of: self)
    }

    override func cancelOperation(_ sender: Any?) { cancel() }

    // MARK: Text

    func textDidChange(_ notification: Notification) {
        if notification.object as AnyObject === title {
            if title.string.contains(where: \.isNewline) {
                title.string = title.string.split(whereSeparator: \.isNewline).joined(separator: " ")
            }
            draft.title = title.string
        } else {
            draft.notes = notes.string
            pasteOpen = true
        }
        onChange(draft)
        refresh()
    }

    func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard view === notes else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        case #selector(NSResponder.insertNewline(_:)) where !model.returnAddsLine:
            save()
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
             #selector(NSResponder.insertLineBreak(_:)):
            return notes.continueList()
        // R62: Tab goes on to the first chip; ⌥Tab still types a tab.
        case #selector(NSResponder.insertTab(_:)):
            guard let first = stops.first else { return false }
            window?.makeFirstResponder(first)
            return true
        default:
            return false
        }
    }

    @objc private func removePasted() { change { $0.notes = "" }; notes.setText("") }

    // MARK: Layout

    private static let margin: CGFloat = 8

    private var insets: NSEdgeInsets {
        footer ? NSEdgeInsets(top: 22, left: 18, bottom: 12, right: 18)
            // In the list the mark and the title stand where those of a row do; the outline reaches past the row (TaskCard.outset).
            : NSEdgeInsets(top: Self.margin + 14, left: 6, bottom: Self.margin + 14, right: 6)
    }

    private struct Frames {
        var outline = NSRect.zero, mark = NSRect.zero, title = NSRect.zero, parsed = NSRect.zero, notes = NSRect.zero
        var paste = NSRect.zero, pasteRemove = NSRect.zero, chips = NSRect.zero, subtasks = NSRect.zero, files = NSRect.zero
        var strip = NSRect.zero, height: CGFloat = 0
    }

    private func textHeight(_ view: NSTextView, width: CGFloat, lines: Int = 1) -> CGFloat {
        guard let container = view.textContainer, let layout = view.layoutManager else { return 0 }
        container.containerSize = NSSize(width: max(width, 1), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let line = TaskTableMetrics.lineHeight(AppFont.native(.body))
        return max(ceil(layout.usedRect(for: container).height), line * CGFloat(lines))
    }

    private func frames(width: CGFloat) -> Frames {
        var f = Frames()
        let insets = self.insets
        let line = TaskTableMetrics.lineHeight(AppFont.native(.body))
        let callout = TaskTableMetrics.lineHeight(AppFont.native(.callout))
        let right = width - insets.right
        var y = insets.top
        // The title row: the mark, the title, what the parser recognised.
        let markSize = mark.image?.size ?? .zero
        f.mark = NSRect(x: insets.left, y: y + (line - markSize.height) / 2, width: markSize.width, height: markSize.height)
        // In the list the title keeps the place a row gives it after the bar of the priority.
        let titleX = f.mark.maxX + 8 + (footer ? 0 : 3 + 8)
        let parsedWidth = parsed.stops.isEmpty ? 0 : min(parsed.stops.reduce(0) { $0 + $1.intrinsicContentSize.width + 6 }, (right - titleX) / 2)
        let titleWidth = max(right - titleX - (parsedWidth > 0 ? parsedWidth + 8 : 0), 1)
        let titleHeight = textHeight(title, width: titleWidth)
        f.title = NSRect(x: titleX, y: y, width: titleWidth, height: titleHeight)
        f.parsed = NSRect(x: right - parsedWidth, y: y, width: parsedWidth, height: parsed.height(width: parsedWidth))
        y += titleHeight + 10
        // Under the title, past the mark: the note, the fields, the subtasks, the files.
        let left = footer ? insets.left + 26 : titleX
        let inner = max(right - left, 1)
        if pasteShown {
            // The button that takes the text away stands inside the block, at its top right.
            let size = pasteRemove.image?.size ?? .zero
            let block = pasteBox.height(width: inner - size.width - 8)
            f.paste = NSRect(x: left, y: y, width: inner, height: block)
            f.pasteRemove = NSRect(x: right - 8 - size.width, y: y + 8, width: size.width, height: size.height)
            y += block + 10
        } else {
            let pasted = !pasteRemove.isHidden
            let notesWidth = inner - (pasted ? 26 : 0)
            let height = textHeight(notes, width: notesWidth, lines: footer ? 3 : 1)
            f.notes = NSRect(x: left, y: y, width: notesWidth, height: height)
            if pasted {
                let size = pasteRemove.image?.size ?? .zero
                f.pasteRemove = NSRect(x: right - size.width, y: y, width: size.width, height: size.height)
            }
            y += height + 10
        }
        let chipsHeight = chipsView.height(width: inner)
        f.chips = NSRect(x: left, y: y, width: inner, height: chipsHeight)
        y += chipsHeight
        if draft.subtasksShown {
            y += 10
            let height = CGFloat(subtaskLines.count + 1) * (callout + 2) + CGFloat(subtaskLines.count) * 6
            f.subtasks = NSRect(x: left, y: y, width: inner, height: height)
            y += height
        }
        if !fileLines.isEmpty {
            y += 10
            let height = CGFloat(fileLines.count) * (callout + 2) + CGFloat(fileLines.count - 1) * 4
            f.files = NSRect(x: left, y: y, width: inner, height: height)
            y += height
        }
        y += insets.bottom
        if footer {
            let stripHeight = callout + 6 + 16
            f.strip = NSRect(x: 0, y: y, width: width, height: stripHeight)
            y += stripHeight
        } else {
            f.outline = NSRect(x: -TaskCard.outset, y: Self.margin, width: width + 2 * TaskCard.outset, height: y - 2 * Self.margin)
        }
        f.height = ceil(y)
        return f
    }

    /// The height the card needs at a width.
    func height(width: CGFloat) -> CGFloat { frames(width: width).height }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let f = frames(width: bounds.width)
        let line = TaskTableMetrics.lineHeight(AppFont.native(.body))
        let callout = TaskTableMetrics.lineHeight(AppFont.native(.callout))
        outline.frame = f.outline
        mark.frame = f.mark
        title.frame = f.title
        titlePlaceholder.frame = NSRect(x: f.title.minX, y: f.title.minY, width: f.title.width, height: line)
        parsed.frame = f.parsed
        notes.frame = f.notes
        notesPlaceholder.frame = NSRect(x: f.notes.minX, y: f.notes.minY, width: f.notes.width, height: line)
        pasteBox.frame = f.paste
        pasteBox.textInset = f.pasteRemove.width + 8
        pasteRemove.frame = f.pasteRemove
        chipsView.frame = f.chips
        subtaskViews.frame = f.subtasks
        var y: CGFloat = 0
        for line in subtaskLines {
            let size = line.mark.image?.size ?? .zero
            line.mark.frame = NSRect(x: 0, y: y + (callout + 2 - size.height) / 2, width: size.width, height: size.height)
            let removeSize = line.remove.image?.size ?? .zero
            line.remove.frame = NSRect(x: f.subtasks.width - removeSize.width, y: y + (callout + 2 - removeSize.height) / 2, width: removeSize.width, height: removeSize.height)
            line.field.frame = NSRect(x: size.width + 6, y: y, width: max(f.subtasks.width - size.width - 12 - removeSize.width, 0), height: callout + 2)
            y += callout + 2 + 6
        }
        let plus = subtaskPlus.image?.size ?? .zero
        subtaskPlus.frame = NSRect(x: 0, y: y + (callout + 2 - plus.height) / 2, width: plus.width, height: plus.height)
        subtaskField.frame = NSRect(x: plus.width + 6, y: y, width: max(f.subtasks.width - plus.width - 6, 0), height: callout + 2)
        filesView.frame = f.files
        y = 0
        for line in fileLines {
            let icon = line.icon.image?.size ?? .zero
            line.icon.frame = NSRect(x: 0, y: y + (callout + 2 - icon.height) / 2, width: icon.width, height: icon.height)
            let nameWidth = min(line.name.fittingSize.width, max(f.files.width - icon.width - 40, 0))
            line.name.frame = NSRect(x: icon.width + 6, y: y, width: nameWidth, height: callout + 2)
            let remove = line.remove.image?.size ?? .zero
            line.remove.frame = NSRect(x: line.name.frame.maxX + 6, y: y + (callout + 2 - remove.height) / 2, width: remove.width, height: remove.height)
            y += callout + 2 + 4
        }
        if footer {
            strip.frame = f.strip
            stripLine.frame = NSRect(x: 0, y: f.strip.minY, width: f.strip.width, height: 1)
            let save = saveButton.intrinsicContentSize
            let cancel = cancelButton.intrinsicContentSize
            let mid = f.strip.midY
            saveButton.frame = NSRect(x: f.strip.maxX - 12 - save.width, y: mid - save.height / 2, width: save.width, height: save.height)
            cancelButton.frame = NSRect(x: saveButton.frame.minX - 8 - cancel.width, y: mid - cancel.height / 2, width: cancel.width, height: cancel.height)
            let list = stripList.fittingSize
            stripList.frame = NSRect(x: 44, y: mid - list.height / 2, width: min(list.width, max(cancelButton.frame.minX - 52, 0)), height: list.height)
        }
    }
}

/// The note taken from the clipboard while it is untouched (R58, R82): set apart, kept short, opened by a click.
@MainActor
private final class PasteBlock: NSView {
    var onClick: () -> Void = {}
    var text = "" { didSet { body.stringValue = text } }
    private let caption = NSTextField(labelWithString: L("From the clipboard"))
    private let body = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        caption.textColor = .tertiaryLabelColor
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 3
        body.lineBreakMode = .byTruncatingTail
        addSubview(caption)
        addSubview(body)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor }

    /// The room the text takes; the button over the block stands to the right of it.
    var textInset: CGFloat = 0

    func height(width: CGFloat) -> CGFloat {
        caption.font = AppFont.native(.caption)
        body.font = AppFont.native(.body)
        body.preferredMaxLayoutWidth = max(width - 16, 1)
        let lines = min(body.fittingSize.height, TaskTableMetrics.lineHeight(AppFont.native(.body)) * 3)
        return 8 + TaskTableMetrics.lineHeight(AppFont.native(.caption)) + 2 + lines + 8
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let captionHeight = TaskTableMetrics.lineHeight(AppFont.native(.caption))
        caption.frame = NSRect(x: 8, y: 8, width: bounds.width - 16, height: captionHeight)
        body.frame = NSRect(x: 8, y: 8 + captionHeight + 2, width: bounds.width - 16 - textInset, height: bounds.height - captionHeight - 18)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick() }
}

/// A button of the strip of the quick-entry panel: a capsule with bold white text (R82).
@MainActor
private final class StripButton: NSButton {
    private let fill: NSColor

    init(title: String, fill: NSColor) {
        self.fill = fill
        super.init(frame: .zero)
        self.title = title
        isBordered = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var label: NSAttributedString {
        let font = AppFont.native(.callout).weighted(.semibold)
        return NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.white])
    }

    override var intrinsicContentSize: NSSize {
        let size = label.size()
        return NSSize(width: ceil(size.width) + 24, height: ceil(size.height) + 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = !isEnabled ? 0.4 : isHighlighted ? 0.75 : 1
        fill.withAlphaComponent(fill.alphaComponent * alpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// The card of a new task in a SwiftUI window: the menu bar window (R24, R82).
struct DraftCardView: NSViewRepresentable {
    var onDone: () -> Void

    func makeNSView(context: Context) -> DraftCard {
        let card = DraftCard(draft: TaskDraft(listId: AppModel.shared.defaultListId), footer: false, escSaves: false)
        card.onClose = { [weak card] in
            card?.sync(TaskDraft(listId: AppModel.shared.defaultListId))
            card?.reset()
            onDone()
        }
        // The window of the menu bar sizes itself by the card.
        card.onResize = { [weak card] in card?.invalidateIntrinsicContentSize() }
        DispatchQueue.main.async { card.focusTitle() }
        return card
    }

    func updateNSView(_ view: DraftCard, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: DraftCard, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 320
        return CGSize(width: width, height: view.height(width: width))
    }
}

extension DraftCard {
    /// Empties the card for the next task, the way the menu bar window starts again after one.
    func reset() {
        title.string = ""
        notes.setText("")
        refresh()
    }
}

/// A container laid out from the top, as the card is.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
