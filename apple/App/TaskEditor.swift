import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The expanded part of a task row: title, note and one row of chips.
/// Fields that are not set take no space; they are added from the "+" menu.
struct TaskEditor: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem

    private enum Popover: Identifiable {
        case due, start, remind, `repeat`, tag
        var id: Self { self }
    }

    @State private var notes = ""
    @State private var popover: Popover?
    @State private var importing = false
    @State private var attachments: [Attachment] = []
    /// Attachments being downloaded on request, and those the last request did not get (R76).
    @State private var fetching: Set<String> = []
    @State private var fetchFailed: Set<String> = []
    @State private var notesFocused = false
    @State private var wantsNotes = false
    @State private var menus = MenuAnchors()
    @FocusState private var chip: CardChip?
    @State private var previewed: URL?
    @State private var previewable: [URL] = []
    @FocusState private var focusedFile: String?

    private var locked: Bool { task.deleted || task.isLog }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            notesField
            chips
            if !attachments.isEmpty { files }
        }
        .disabled(locked)
        .background {
            // The dates and the repeat of the selected open task are one key away; the card
            // of a parent stays open around its subtask, and only the selected one answers.
            Group {
                Button("") { popover = .start }.keyboardShortcut("s", modifiers: .command)
                Button("") { popover = .due }.keyboardShortcut("d", modifiers: .command)
                Button("") { popover = .repeat }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("", action: paste).keyboardShortcut("v", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
            .disabled(locked || model.selection != task.id || model.draft != nil)
        }
        .onAppear(perform: load)
        .onChange(of: task) { _, _ in load() }
        .onChange(of: model.attachmentsArrived) { _, _ in load() }
        // A chip that is gone, a tag just removed for one, hands the keyboard to the chip that took its place.
        .onChange(of: stops) { before, now in
            guard let chip, !now.contains(chip), let index = before.firstIndex(of: chip) else { return }
            self.chip = now[min(index, now.count - 1)]
        }
        .reportsCard(task.id, chip: chip, file: attachments.first { $0.id == focusedFile }?.name, popover: popover.map { "\($0)" })
        .onDisappear(perform: commitNotes)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attach(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls.filter(\.isFileURL))
            return true
        }
    }

    private var notesField: some View {
        ZStack(alignment: .topLeading) {
            if notes.isEmpty {
                Text(L("Notes")).foregroundStyle(.tertiary).allowsHitTesting(false)
            }
            NotesTextView(
                text: $notes, font: AppFont.native(.body), returnAddsLine: model.returnAddsLine,
                wantsFocus: $wantsNotes,
                onEditingChanged: { editing in
                    notesFocused = editing
                    if !editing { commitNotes() }
                },
                onFinish: finish,
                // The binding gets the new text first; the note is saved right after it.
                onToggle: { DispatchQueue.main.async { commitNotes() } },
                onTab: { chip = stops.first })
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(AppFont.style(.body))
    }

    private func finish() {
        // Esc with a popover open is for the popover: it reaches the card as well.
        if popover != nil { return popover = nil }
        commitNotes()
        model.closeCard(task.id)
    }

    private func load() {
        if !notesFocused { notes = task.notes }
        attachments = (try? model.store?.attachments(taskId: task.id)) ?? []
    }

    private func commitNotes() {
        guard !locked, notes != task.notes else { return }
        model.perform { try $0.setNotes(id: task.id, notes: notes) }
    }

    private func attach(_ urls: [URL]) {
        model.attach(urls, to: task.id)
        load()
    }

    /// ⌘V with files or an image attaches them; with text it pastes as usual.
    private func paste() {
        let pasted = IncomingFiles.pasted()
        if pasted.isEmpty {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        } else {
            attach(pasted)
        }
    }

    // MARK: Chips

    /// The chips in the order they are drawn, which is the order Tab walks them in (R62).
    private var stops: [CardChip] {
        [.start, .due] + (showsRepeat ? [.repeat] : []) + (showsRemind ? [.remind] : []) + [.priority] + task.tags.map(CardChip.tag) + [.add] + (task.done == nil ? [.wont] : [])
    }

    private var showsRepeat: Bool { task.repeat != nil || popover == .repeat }
    private var showsRemind: Bool { task.remind != nil || popover == .remind }

    private var keys: ChipKeys {
        ChipKeys(step: { from, by in
            guard let index = stops.firstIndex(of: from) else { return }
            if index + by < 0 {
                wantsNotes = true
            } else if index + by >= stops.count {
                model.titleFocus = task.id
            } else {
                chip = stops[index + by]
            }
        }, cancel: finish)
    }

    private var priorityChoices: [MenuChoice] {
        Priority.all.map { priority in
            MenuChoice(title: priority.title, on: task.priority == priority) { model.perform { try $0.setPriority(id: task.id, priority: priority) } }
        }
    }

    private var addChoices: [MenuChoice] {
        var choices: [MenuChoice] = []
        if task.repeat == nil { choices.append(MenuChoice(title: L("Repeat")) { popover = .repeat }) }
        if task.remind == nil { choices.append(MenuChoice(title: L("Reminder")) { popover = .remind }) }
        choices.append(MenuChoice(title: L("Tag")) { popover = .tag })
        if !model.showsSubtasks(task) { choices.append(MenuChoice(title: L("Subtask")) { model.showSubtasks(task.id) }) }
        choices.append(MenuChoice(title: L("File or image…")) { importing = true })
        return choices
    }

    private var chips: some View {
        FlowLayout(spacing: 6) {
            // Both dates are always on show: when the work begins and when it is due.
            chipButton(.start, symbol: "calendar.badge.clock", text: task.start.map { L("Start: ") + Moment.label($0).lowercased() } ?? L("Start"),
                       tint: task.start == nil ? .secondary : .accentColor)
                .popover(isPresented: isOpen(.start)) {
                    DateEditor(title: L("Start: hidden from Today until"), value: task.start) { value in model.perform { try $0.setStart(id: task.id, start: value) } }
                }
                .help(L("Start date (⌘S)"))
                .chipStop(.start, focus: $chip, keys: keys) { popover = .start }
            chipButton(.due, symbol: "calendar", text: task.due.map { L("Due: ") + Moment.label($0).lowercased() } ?? L("Due"),
                       tint: task.due.map { Moment.isOverdue($0) && task.done == nil ? Color.red : .accentColor } ?? .secondary)
                .popover(isPresented: isOpen(.due)) {
                    DateEditor(title: L("Due"), value: task.due) { value in model.perform { try $0.setDue(id: task.id, due: value) } }
                }
                .help(L("Due date (⌘D)"))
                .chipStop(.due, focus: $chip, keys: keys) { popover = .due }
            if showsRepeat {
                chipButton(.repeat, symbol: "repeat", text: task.repeat?.summary ?? L("Repeat"), tint: .accentColor)
                    .popover(isPresented: isOpen(.repeat)) {
                        RepeatEditor(value: task.repeat) { rule in model.perform { try $0.setRepeat(id: task.id, repeat: rule) } }
                    }
                    .help(L("Repeat (⇧⌘R)"))
                    .chipStop(.repeat, focus: $chip, keys: keys) { popover = .repeat }
            }
            if showsRemind {
                chipButton(.remind, symbol: "bell", text: task.remind.map(Moment.label) ?? L("Reminder"), tint: .accentColor)
                    .popover(isPresented: isOpen(.remind)) {
                        DateEditor(title: L("Remind me"), value: task.remind, timeRequired: true) { value in
                            model.perform { try $0.setRemind(id: task.id, remind: value) }
                        }
                    }
                    .chipStop(.remind, focus: $chip, keys: keys) { popover = .remind }
            }
            Menu {
                ChoiceItems(choices: priorityChoices)
            } label: {
                Chip(symbol: "flag", text: task.priority == .none ? "" : task.priority.title, tint: task.priority == .none ? .secondary : .orange)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Priority"))
            .menuAnchor(menus, .priority)
            .chipStop(.priority, focus: $chip, keys: keys) { menus.show(priorityChoices, under: .priority) }

            ForEach(task.tags, id: \.self) { tag in
                Button {
                    model.perform { try $0.removeTag(id: task.id, tag: tag) }
                } label: {
                    Chip(symbol: nil, text: "#\(tag) ×")
                }
                .buttonStyle(.plain)
                .help(L("Remove tag"))
                .chipStop(.tag(tag), focus: $chip, keys: keys) { model.perform { try $0.removeTag(id: task.id, tag: tag) } }
            }

            Menu {
                ChoiceItems(choices: addChoices)
            } label: {
                Chip(symbol: "plus", text: "")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Add field"))
            .popover(isPresented: isOpen(.tag)) {
                TagEditor(known: model.tags.map(\.name).filter { !task.tags.contains($0) }) { tag in
                    model.perform { try $0.addTag(id: task.id, tag: tag) }
                }
            }
            .menuAnchor(menus, .add)
            .chipStop(.add, focus: $chip, keys: keys) { menus.show(addChoices, under: .add) }

            if task.done == nil {
                Button {
                    model.wontDo(task)
                } label: {
                    Chip(symbol: "xmark.square", text: L("Won't do"))
                }
                .buttonStyle(.plain)
                .help(L("Close the task without doing it"))
                .chipStop(.wont, focus: $chip, keys: keys) { model.wontDo(task) }
            }
        }
    }

    private func isOpen(_ which: Popover) -> Binding<Bool> {
        Binding(get: { popover == which }, set: { if !$0 && popover == which { popover = nil } })
    }

    private func chipButton(_ which: Popover, symbol: String, text: String, tint: Color) -> some View {
        Button { popover = which } label: { Chip(symbol: symbol, text: text, tint: tint) }
            .buttonStyle(.plain)
    }

    // MARK: Attachments

    private var files: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(attachments, id: \.id) { file in
                HStack(spacing: 6) {
                    AttachmentIcon(file: file)
                    Button(file.name) { open(file) }
                        .buttonStyle(.link)
                        .disabled(fetching.contains(file.id))
                        .help(file.localPath == nil ? L("Download now") : "")
                    Text(caption(file))
                        .font(AppFont.style(.caption))
                        .foregroundStyle(.tertiary)
                    Button {
                        model.perform { try $0.removeAttachment(id: file.id) }
                        load()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Remove attachment"))
                }
                .font(AppFont.style(.callout))
                // The row takes the keyboard after a click, so Space shows the file the way it does in Finder.
                .focusable(file.localPath != nil)
                .focused($focusedFile, equals: file.id)
                .onKeyPress(.space) {
                    show(file)
                    return .handled
                }
                // The list leaves its keys alone while the row has the keyboard, Esc among them.
                .onKeyPress(.escape) {
                    finish()
                    return .handled
                }
                .contextMenu {
                    if file.localPath != nil {
                        Button(L("Quick Look")) { show(file) }
                        Button(L("Open in Default App")) {
                            if let url = AttachmentFiles.named(file) { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }
        }
        .quickLookPreview($previewed, in: previewable)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugScript.showFile)) { note in
            guard model.selection == task.id, let index = note.object as? Int, attachments.indices.contains(index) else { return }
            open(attachments[index])
        }
        #endif
    }

    private func caption(_ file: Attachment) -> String {
        if file.localPath != nil { return ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file) }
        if fetching.contains(file.id) { return L("downloading…") }
        return fetchFailed.contains(file.id) ? L("could not download, try again later") : L("not downloaded yet, click to download")
    }

    private func open(_ file: Attachment) {
        if file.localPath == nil { fetch(file) } else { show(file) }
    }

    /// R76: a file that has not arrived is downloaded ahead of the others and shown.
    private func fetch(_ file: Attachment) {
        guard let store = model.store, !fetching.contains(file.id) else { return }
        let id = file.id
        fetching.insert(id)
        fetchFailed.remove(id)
        _Concurrency.Task {
            let arrived = await _Concurrency.Task.detached(priority: .userInitiated) {
                (try? store.fetchAttachment(id: id))?.localPath != nil
            }.value
            fetching.remove(id)
            guard arrived else {
                fetchFailed.insert(id)
                return
            }
            model.attachmentsMoved(arrived: true)
            load()
            if let got = attachments.first(where: { $0.id == id }) { show(got) }
        }
    }

    /// Shows the file inside the app (R54); the system decides how from its name.
    /// The panel pages through the files of the task that are on this device.
    private func show(_ file: Attachment) {
        guard let url = AttachmentFiles.named(file) else { return }
        #if DEBUG
        DebugScript.shows += 1
        #endif
        focusedFile = file.id
        previewable = attachments.compactMap(AttachmentFiles.named)
        previewed = url
    }
}

/// The title of an expanded task, edited in place of the row's text.
struct TaskTitleField: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(L("Title"), text: $title)
            .textFieldStyle(.plain)
            .font(AppFont.style(.body))
            .focused($focused)
            .onSubmit(commit)
            .onAppear {
                title = task.title
                takeKeyboard()
            }
            .onChange(of: model.titleFocus) { _, _ in takeKeyboard() }
            .onChange(of: task.title) { _, new in if !focused { title = new } }
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onDisappear(perform: commit)
    }

    /// Takes the keyboard when the card was opened for typing, with the caret after the title.
    private func takeKeyboard() {
        guard model.titleFocus == task.id else { return }
        model.titleFocus = nil
        // On the next turn: the row is not in the table yet while it appears.
        DispatchQueue.main.async {
            focused = true
            // A field that takes the keyboard selects its text; the caret goes in once it has.
            DispatchQueue.main.async {
                guard let text = Keyboard.text else { return }
                text.selectedRange = NSRange(location: text.string.utf16.count, length: 0)
            }
        }
    }

    private func commit() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != task.title else { return }
        if value.isEmpty { title = task.title; return }
        model.perform { try $0.setTitle(id: task.id, title: value) }
    }
}

/// Date with optional time, with the common choices one click away.
struct DateEditor: View {
    let title: String
    let value: String?
    var timeRequired = false
    let apply: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var withTime = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(AppFont.style(.headline))
            HStack(alignment: .top, spacing: 12) {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 6) {
                    choice(L("Today"), key: "T", days: 0)
                    choice(L("Tomorrow"), key: "M", days: 1)
                    choice(L("In a week"), key: "W", days: 7)
                    Group {
                        Text(L("1–9  in that many days"))
                        Text(L("+ −  a day later, earlier"))
                    }
                    .font(AppFont.style(.caption))
                    .foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
            HStack {
                if !timeRequired { Toggle(L("Time"), isOn: $withTime) }
                if withTime {
                    DatePicker("", selection: $date, displayedComponents: .hourAndMinute).labelsHidden()
                }
            }
            HStack {
                if value != nil {
                    Button(role: .destructive) { apply(nil); dismiss() } label: {
                        keyed(L("Remove"), key: "⌫")
                    }
                }
                Spacer()
                Button(L("Done"), action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .fixedSize()
        .background(KeyCatcher(handle: press))
        .onAppear {
            withTime = timeRequired || value.map(Moment.hasTime) ?? false
            if let value, let parsed = Moment.date(value) {
                date = parsed
            } else if timeRequired {
                date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date().addingTimeInterval(86400)) ?? Date()
            }
        }
    }

    private func confirm() {
        apply(Moment.string(date, withTime: withTime))
        dismiss()
    }

    private func pick(days: Int) {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: Date())) ?? Date()
        let time = calendar.dateComponents([.hour, .minute], from: date)
        date = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
        apply(Moment.string(date, withTime: withTime))
        dismiss()
    }

    private func choice(_ title: String, key: String, days: Int) -> some View {
        Button { pick(days: days) } label: { keyed(title, key: key) }
    }

    /// A button label with the key that does the same (R39).
    private func keyed(_ title: String, key: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text(key).foregroundStyle(.secondary)
        }
    }

    /// The common choices from the keyboard (R39). The time field keeps its keys while it is typed into;
    /// Return confirms from there as well.
    private func press(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = DateKey(code: event.keyCode), key == .confirm || !Self.editingTime(in: event.window) else { return false }
        switch key {
        case .confirm: confirm()
        case .pick(let days): pick(days: days)
        case .shift(let days): date = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
        case .remove:
            guard value != nil else { return false }
            apply(nil)
            dismiss()
        }
        return true
    }

    /// The calendar and the time field are both date pickers; only the time field takes typing.
    private static func editingTime(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? NSDatePicker).map { $0.datePickerStyle != .clockAndCalendar } ?? false
    }
}

/// What a key does in the date popover. Keys are told by their place on the
/// keyboard, not by the character, so every layout gives the same choices.
enum DateKey: Equatable {
    case pick(days: Int), shift(days: Int), remove, confirm

    private static let digits: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
        83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9,
    ]

    init?(code: UInt16) {
        switch code {
        case 17: self = .pick(days: 0) // T
        case 46: self = .pick(days: 1) // M
        case 13: self = .pick(days: 7) // W
        case 24, 69: self = .shift(days: 1) // = and + of the main block, + of the keypad
        case 27, 78: self = .shift(days: -1)
        case 51, 117: self = .remove // ⌫ and ⌦
        case 36, 76: self = .confirm // Return and Enter of the keypad
        default:
            guard let days = Self.digits[code] else { return nil }
            self = .pick(days: days)
        }
    }
}

/// Shows the key presses headed for the window it sits in to `handle` before
/// the focused control gets them; a press that was handled goes no further.
private struct KeyCatcher: NSViewRepresentable {
    let handle: (NSEvent) -> Bool

    func makeNSView(context: Context) -> Catcher { Catcher() }

    func updateNSView(_ view: Catcher, context: Context) { view.handle = handle }

    final class Catcher: NSView {
        var handle: (NSEvent) -> Bool = { _ in false }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.receives(event), self.handle(event) else { return event }
                return nil
            }
        }

        /// A press in a popover comes with the window the popover hangs on, whose
        /// first responder is then a view of the popover.
        private func receives(_ event: NSEvent) -> Bool {
            guard let window else { return false }
            return event.window === window || (event.window?.firstResponder as? NSView)?.window === window
        }
    }
}

struct TagEditor: View {
    let known: [String]
    let add: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L("Tag"), text: $text)
                .frame(width: 180)
                .onSubmit {
                    let tag = text.trimmingCharacters(in: .whitespaces)
                    if !tag.isEmpty { add(tag) }
                    dismiss()
                }
            ForEach(known.prefix(8), id: \.self) { tag in
                Button("#\(tag)") { add(tag); dismiss() }.buttonStyle(.link)
            }
        }
        .padding(12)
    }
}

/// Presets first; the custom controls appear only when asked for.
struct RepeatEditor: View {
    let value: Repeat?
    let apply: (Repeat?) -> Void

    private enum Ending: Hashable { case never, count, until }
    private enum MonthMode: Hashable { case day, weekday }

    @Environment(\.dismiss) private var dismiss
    @State private var custom = false
    @State private var freq = Freq.weekly
    @State private var interval = 1
    @State private var weekdays: Set<UInt32> = []
    @State private var monthMode = MonthMode.day
    @State private var nth = 1
    @State private var nthWeekday = 1
    @State private var fromDone = false
    @State private var ending = Ending.never
    @State private var count = 5
    @State private var until = Date().addingTimeInterval(30 * 86400)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !custom {
                ForEach(Repeat.presets, id: \.0) { name, rule in
                    Button {
                        apply(rule)
                        dismiss()
                    } label: {
                        HStack {
                            Text(name)
                            Spacer()
                            if value?.presetName == name { Image(systemName: "checkmark") }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Divider()
                Button(L("Custom…")) { custom = true }.buttonStyle(.plain)
                if value != nil {
                    Button(L("Do not repeat"), role: .destructive) { apply(nil); dismiss() }.buttonStyle(.plain)
                }
            } else {
                customForm
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear(perform: load)
    }

    private var customForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Every"))
                Stepper(value: $interval, in: 1...999) { Text("\(interval)").monospacedDigit() }
                Picker("", selection: $freq) {
                    Text(L("days")).tag(Freq.daily)
                    Text(L("weeks")).tag(Freq.weekly)
                    Text(L("months")).tag(Freq.monthly)
                    Text(L("years")).tag(Freq.yearly)
                }
                .labelsHidden()
                .fixedSize()
            }
            if freq == .weekly {
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        let d = UInt32(day)
                        Toggle(Repeat.weekdayNames[day - 1], isOn: Binding(
                            get: { weekdays.contains(d) },
                            set: { if $0 { weekdays.insert(d) } else { weekdays.remove(d) } }))
                            .toggleStyle(.button)
                            .controlSize(.small)
                    }
                }
            }
            if freq == .monthly {
                Picker("", selection: $monthMode) {
                    Text(L("On a day of the month")).tag(MonthMode.day)
                    Text(L("On a day of the week")).tag(MonthMode.weekday)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if monthMode == .weekday {
                    HStack {
                        Picker("", selection: $nth) {
                            ForEach(1...5, id: \.self) { Text(ordinal($0)).tag($0) }
                            Text(L("last")).tag(-1)
                        }
                        Picker("", selection: $nthWeekday) {
                            ForEach(1...7, id: \.self) { Text(Repeat.weekdayNames[$0 - 1]).tag($0) }
                        }
                    }
                    .labelsHidden()
                }
            }
            Toggle(L("Count from the completion date"), isOn: $fromDone)
            Picker(L("Ends"), selection: $ending) {
                Text(L("Never")).tag(Ending.never)
                Text(L("After a number of repeats")).tag(Ending.count)
                Text(L("On a date")).tag(Ending.until)
            }
            if ending == .count {
                Stepper(L("Repeats: %@", "\(count)"), value: $count, in: 1...99)
            }
            if ending == .until {
                DatePicker(L("Until"), selection: $until, displayedComponents: .date)
            }
            HStack {
                Button(L("Back")) { custom = false }
                Spacer()
                Button(L("Done")) { apply(rule); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var rule: Repeat {
        let byWeekday = freq == .monthly && monthMode == .weekday
        return Repeat(
            freq: freq,
            interval: UInt32(interval),
            weekdays: freq == .weekly ? weekdays.sorted() : [],
            monthday: nil,
            nth: byWeekday ? Int32(nth) : nil,
            nthWeekday: byWeekday ? UInt32(nthWeekday) : nil,
            fromDone: fromDone,
            count: ending == .count ? UInt32(count) : nil,
            until: ending == .until ? Moment.string(until, withTime: false) : nil)
    }

    private func load() {
        guard let value else { return }
        custom = value.presetName == nil
        freq = value.freq
        interval = Int(value.interval)
        weekdays = Set(value.weekdays)
        if let n = value.nth, let wd = value.nthWeekday {
            monthMode = .weekday
            nth = Int(n)
            nthWeekday = Int(wd)
        }
        fromDone = value.fromDone
        if let c = value.count {
            ending = .count
            count = Int(c)
        } else if let u = value.until, let date = Moment.date(u) {
            ending = .until
            until = date
        }
    }
}

/// Lays chips out left to right and wraps them onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (index, point) in rows.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxWidth = max(maxWidth, x - spacing)
        }
        return (points, maxWidth, y + rowHeight)
    }
}
