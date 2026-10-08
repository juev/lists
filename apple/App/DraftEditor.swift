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
    /// Set when the task is typed inside a project: it becomes a subtask of it.
    var parentId: String?
    /// Attached once the task exists.
    var files: [URL] = []

    var isBlank: Bool { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The card of a new task, the same in the main window (⌘N) and in the
/// quick-entry panel: every field can be filled before the task is created.
/// Return in the title and ⌘Return anywhere save; Esc throws the card away (R37).
struct DraftEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: TaskDraft
    /// Called when the card is done with, saved or not.
    var onClose: () -> Void
    /// Called when the height may have changed; the quick-entry panel follows it.
    var onResize: () -> Void = {}
    /// The quick-entry panel: the card pads itself and ends with a strip that holds the list and the two buttons (R82).
    var footer = false

    private enum Popover: Identifiable {
        case due, start, `repeat`, tag
        var id: Self { self }
    }

    @State private var popover: Popover?
    @State private var wantsNotes = false
    /// The note taken from the clipboard was opened for editing: it is drawn as an ordinary note from then on.
    @State private var pasteOpen = false
    /// Where the chips stood when a popover opened: a chip does not change sides under its own popover.
    @State private var held: Sides?
    @State private var menus = MenuAnchors()
    @FocusState private var titleFocused: Bool
    @FocusState private var chip: CardChip?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    // A task that does not exist yet has nothing to complete: the mark only says what the card is.
                    Image(systemName: "square").font(AppFont.style(.body)).foregroundStyle(.tertiary)
                    TextField(L("New task"), text: $draft.title)
                        .textFieldStyle(.plain)
                        .font(AppFont.style(.title3, weight: .semibold))
                        .focused($titleFocused)
                        .onSubmit(close)
                    if model.parseQuickText { QuickChips(text: draft.title) }
                }
                Group {
                    notes
                    fields
                    if !draft.files.isEmpty { files }
                }
                .padding(.leading, 26)
            }
            .padding(.horizontal, footer ? 18 : 0)
            .padding(.top, footer ? 16 : 0)
            .padding(.bottom, footer ? 12 : 0)
            if footer { strip }
        }
        .background {
            // The dates and the repeat are one key away from wherever the cursor is.
            Group {
                Button("") { popover = .start }.keyboardShortcut("s", modifiers: .command)
                Button("") { popover = .due }.keyboardShortcut("d", modifiers: .command)
                Button("") { popover = .repeat }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("", action: paste).keyboardShortcut("v", modifiers: .command)
                // Esc throws the card away, so saving has a key that works in the note as well.
                Button("", action: close).keyboardShortcut(.return, modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear { titleFocused = true }
        .onExitCommand(perform: cancel)
        .onChange(of: popover) { _, now in held = now == nil ? nil : sides }
        .onChange(of: pasteShown) { _, _ in onResize() }
        // A chip that is gone, a tag just removed for one, hands the keyboard to the chip that took its place.
        .onChange(of: stops) { before, now in
            guard let chip, !now.contains(chip), let index = before.firstIndex(of: chip) else { return }
            self.chip = now[min(index, now.count - 1)]
        }
        .reportsCard("draft", chip: chip, popover: popover.map { "\($0)" })
        .onChange(of: draft.notes) { _, _ in onResize() }
        .onChange(of: draft.tags) { _, _ in onResize() }
        .onChange(of: draft.repeat) { _, _ in onResize() }
        .onChange(of: draft.files) { _, _ in onResize() }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls.filter(\.isFileURL))
            return true
        }
    }

    /// Return, ⌘Return and "Save": the task is created when it has a title.
    private func close() {
        if draft.isBlank {
            draft.files.forEach(IncomingFiles.discard)
        } else {
            model.save(draft)
        }
        onClose()
    }

    /// Esc and "Cancel": the card goes and nothing is created (R37).
    private func cancel() {
        // Esc with a popover open is for the popover: it reaches the card as well.
        if popover != nil { return popover = nil }
        draft.files.forEach(IncomingFiles.discard)
        onClose()
    }

    /// The note came from the clipboard and has not been touched or opened (R58).
    private var pasteShown: Bool {
        guard !pasteOpen, let pasted = draft.pastedNotes else { return false }
        return !pasted.isEmpty && draft.notes == pasted
    }

    private var notes: some View {
        HStack(alignment: .top, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if draft.notes.isEmpty {
                    Text(L("Notes")).foregroundStyle(.tertiary).allowsHitTesting(false)
                }
                // The editor stays in the card while the block is shown, so Tab from the title still reaches it.
                NotesTextView(
                    text: $draft.notes, font: AppFont.native(.body), returnAddsLine: model.returnAddsLine,
                    wantsFocus: $wantsNotes, onEditingChanged: { editing in if editing { pasteOpen = true } },
                    onFinish: close, onCancel: cancel, onTab: { chip = stops.first })
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: pasteShown ? 0 : nil)
                    .opacity(pasteShown ? 0 : 1)
                if pasteShown {
                    // R82: what the clipboard gave is set apart and kept short until it is wanted.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("From the clipboard")).font(AppFont.style(.caption)).foregroundStyle(.tertiary)
                        Text(draft.notes).lineLimit(3).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        pasteOpen = true
                        wantsNotes = true
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // R58: the text taken from the clipboard goes in one click while it is untouched.
            if let pasted = draft.pastedNotes, draft.notes == pasted {
                Button { draft.notes = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L("Remove the text taken from the clipboard"))
            }
        }
        .font(AppFont.style(.body))
        .padding(pasteShown ? 8 : 0)
        .background(Color.primary.opacity(pasteShown ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 9))
    }

    /// The strip at the bottom of the quick-entry panel: where the task goes, and the two ways out.
    private var strip: some View {
        HStack(spacing: 8) {
            if draft.parentId == nil { listMenu(strong: true) }
            Spacer(minLength: 8)
            Button(L("Cancel"), action: cancel)
            Button(L("Save"), action: close)
                .buttonStyle(.borderedProminent)
                .disabled(draft.isBlank)
        }
        .padding(.leading, 44)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05))
        .overlay(alignment: .top) { Divider() }
    }

    /// ⌘V with files or an image attaches them; with text it pastes as usual.
    private func paste() {
        let pasted = IncomingFiles.pasted()
        if pasted.isEmpty {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        } else {
            add(pasted)
        }
    }

    private func add(_ urls: [URL]) {
        draft.files.append(contentsOf: urls.filter { !draft.files.contains($0) })
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(draft.files, id: \.self) { url in
                HStack(spacing: 6) {
                    Image(systemName: "paperclip").foregroundStyle(.secondary)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Button {
                        draft.files.removeAll { $0 == url }
                        IncomingFiles.discard(url)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Remove attachment"))
                }
                .font(AppFont.style(.callout))
            }
        }
    }

    /// The chips of the two sides of the row: what is set stands at the left with its value, the rest at the right as icons (R82).
    private struct Sides: Equatable {
        var left: [CardChip]
        var right: [CardChip]
    }

    private var sides: Sides {
        if let held { return held }
        let dated: [(CardChip, Bool)] = [
            (.start, draft.start != nil), (.due, shownDue != nil), (.repeat, draft.repeat != nil), (.priority, shownPriority != .none),
        ]
        return Sides(
            left: dated.filter(\.1).map(\.0) + draft.tags.map(CardChip.tag) + (draft.parentId == nil && !footer ? [.list] : []),
            right: dated.filter { !$0.1 }.map(\.0) + [.newTag, .file])
    }

    /// The chips in the order they are drawn, which is the order Tab walks them in (R62).
    private var stops: [CardChip] {
        sides.left + sides.right + (draft.parentId == nil && footer ? [.list] : [])
    }

    private var keys: ChipKeys {
        ChipKeys(step: { from, by in
            guard let index = stops.firstIndex(of: from) else { return }
            if index + by < 0 {
                wantsNotes = true
            } else if index + by >= stops.count {
                titleFocused = true
            } else {
                chip = stops[index + by]
            }
        }, cancel: cancel)
    }

    private var priorityChoices: [MenuChoice] {
        Priority.all.map { priority in
            MenuChoice(title: priority.title, on: shownPriority == priority) {
                draft.priority = priority
                draft.priorityChosen = true
            }
        }
    }

    private var listChoices: [MenuChoice] {
        model.lists.filter { !$0.archived }.map { list in
            MenuChoice(title: model.listName(list), on: draft.listId == list.id) { draft.listId = list.id }
        }
    }

    private var fields: some View {
        HStack(alignment: .center, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(sides.left, id: \.self) { field($0, set: true) }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ForEach(sides.right, id: \.self) { field($0, set: false) }
            }
        }
    }

    /// One field of the row: a chip with its value when it is set, an icon when it is not.
    @ViewBuilder
    private func field(_ which: CardChip, set: Bool) -> some View {
        switch which {
        case .start:
            chipButton(.start, symbol: "calendar.badge.clock",
                       text: draft.start.map { L("Start: ") + Moment.label($0).lowercased() } ?? "", set: set)
                .popover(isPresented: isOpen(.start)) {
                    DateEditor(title: L("Start: hidden from Today until"), value: draft.start) { draft.start = $0 }
                }
                .help(L("Start date (⌘S)"))
                .chipStop(.start, focus: $chip, keys: keys) { popover = .start }
        case .due:
            chipButton(.due, symbol: "calendar",
                       text: shownDue.map { L("Due: ") + Moment.label($0).lowercased() } ?? "", set: set)
                .popover(isPresented: isOpen(.due)) {
                    DateEditor(title: L("Due"), value: shownDue) {
                        draft.due = $0
                        draft.dueRemoved = $0 == nil
                    }
                }
                .help(L("Due date (⌘D)"))
                .chipStop(.due, focus: $chip, keys: keys) { popover = .due }
        case .repeat:
            chipButton(.repeat, symbol: "repeat", text: draft.repeat?.summary ?? "", set: set)
                .popover(isPresented: isOpen(.repeat)) {
                    RepeatEditor(value: draft.repeat) { draft.repeat = $0 }
                }
                .help(L("Repeat (⇧⌘R)"))
                .chipStop(.repeat, focus: $chip, keys: keys) { popover = .repeat }
        case .priority:
            Menu {
                ChoiceItems(choices: priorityChoices)
            } label: {
                Chip(symbol: "flag", text: shownPriority == .none ? "" : shownPriority.title, tint: shownPriority == .none ? .secondary : .orange, plain: !set)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Priority"))
            .menuAnchor(menus, .priority)
            .chipStop(.priority, focus: $chip, keys: keys) { menus.show(priorityChoices, under: .priority) }
        case .tag(let tag):
            Button {
                draft.tags.removeAll { $0 == tag }
            } label: {
                Chip(symbol: nil, text: "#\(tag) ×")
            }
            .buttonStyle(.plain)
            .help(L("Remove tag"))
            .chipStop(.tag(tag), focus: $chip, keys: keys) { draft.tags.removeAll { $0 == tag } }
        case .newTag:
            Button { popover = .tag } label: { Chip(symbol: "number", text: "", plain: true) }
                .buttonStyle(.plain)
                .popover(isPresented: isOpen(.tag)) {
                    TagEditor(known: model.tags.map(\.name).filter { !draft.tags.contains($0) }) { tag in
                        if !draft.tags.contains(tag) { draft.tags.append(tag) }
                    }
                }
                .help(L("Tag"))
                .chipStop(.newTag, focus: $chip, keys: keys) { popover = .tag }
        case .list:
            listMenu(strong: false)
        case .file:
            Button { add(IncomingFiles.pick()) } label: { Chip(symbol: "paperclip", text: "", plain: true) }
                .buttonStyle(.plain)
                .help(L("File or image"))
                .chipStop(.file, focus: $chip, keys: keys) { add(IncomingFiles.pick()) }
        default:
            EmptyView()
        }
    }

    /// The list the task goes to: a chip in the row, or the first thing in the strip of the quick-entry panel.
    private func listMenu(strong: Bool) -> some View {
        let list = model.list(draft.listId)
        let name = list.map(model.listName) ?? L("Inbox")
        return Menu {
            ChoiceItems(choices: listChoices)
        } label: {
            if strong {
                Label(name, systemImage: list?.symbol ?? "tray")
                    .font(AppFont.style(.callout, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Chip(symbol: "list.bullet", text: name)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("List"))
        .menuAnchor(menus, .list)
        .chipStop(.list, focus: $chip, keys: keys) { menus.show(listChoices, under: .list) }
    }

    private var shownDue: String? { model.shownDue(draft) }

    private var shownPriority: Priority { model.shownPriority(draft) }

    private func isOpen(_ which: Popover) -> Binding<Bool> {
        Binding(get: { popover == which }, set: { if !$0 && popover == which { popover = nil } })
    }

    private func chipButton(_ which: Popover, symbol: String, text: String, set: Bool) -> some View {
        Button { popover = which } label: { Chip(symbol: symbol, text: text, tint: set ? .accentColor : .secondary, plain: !set) }
            .buttonStyle(.plain)
    }
}
