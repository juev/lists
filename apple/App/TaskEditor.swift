import AppKit
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
    @State private var notesFocused = false

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
                wantsFocus: .constant(false),
                onEditingChanged: { editing in
                    notesFocused = editing
                    if !editing { commitNotes() }
                },
                onFinish: finish)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(AppFont.style(.body))
    }

    private func finish() {
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

    private var chips: some View {
        FlowLayout(spacing: 6) {
            // Both dates are always on show: when the work begins and when it is due.
            chipButton(.start, symbol: "calendar.badge.clock", text: task.start.map { L("Start: ") + Moment.label($0).lowercased() } ?? L("Start"),
                       tint: task.start == nil ? .secondary : .accentColor)
                .popover(isPresented: isOpen(.start)) {
                    DateEditor(title: L("Start: hidden from Today until"), value: task.start) { value in model.perform { try $0.setStart(id: task.id, start: value) } }
                }
                .help(L("Start date (⌘S)"))
            chipButton(.due, symbol: "calendar", text: task.due.map { L("Due: ") + Moment.label($0).lowercased() } ?? L("Due"),
                       tint: task.due.map { Moment.isOverdue($0) && task.done == nil ? Color.red : .accentColor } ?? .secondary)
                .popover(isPresented: isOpen(.due)) {
                    DateEditor(title: L("Due"), value: task.due) { value in model.perform { try $0.setDue(id: task.id, due: value) } }
                }
                .help(L("Due date (⌘D)"))
            if task.repeat != nil || popover == .repeat {
                chipButton(.repeat, symbol: "repeat", text: task.repeat?.summary ?? L("Repeat"), tint: .accentColor)
                    .popover(isPresented: isOpen(.repeat)) {
                        RepeatEditor(value: task.repeat) { rule in model.perform { try $0.setRepeat(id: task.id, repeat: rule) } }
                    }
                    .help(L("Repeat (⇧⌘R)"))
            }
            if task.remind != nil || popover == .remind {
                chipButton(.remind, symbol: "bell", text: task.remind.map(Moment.label) ?? L("Reminder"), tint: .accentColor)
                    .popover(isPresented: isOpen(.remind)) {
                        DateEditor(title: L("Remind me"), value: task.remind, timeRequired: true) { value in
                            model.perform { try $0.setRemind(id: task.id, remind: value) }
                        }
                    }
            }
            Menu {
                ForEach(Priority.all, id: \.self) { priority in
                    Toggle(priority.title, isOn: Binding(
                        get: { task.priority == priority },
                        set: { _ in model.perform { try $0.setPriority(id: task.id, priority: priority) } }))
                }
            } label: {
                Chip(symbol: "flag", text: task.priority == .none ? "" : task.priority.title, tint: task.priority == .none ? .secondary : .orange)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Priority"))

            ForEach(task.tags, id: \.self) { tag in
                Button {
                    model.perform { try $0.removeTag(id: task.id, tag: tag) }
                } label: {
                    Chip(symbol: nil, text: "#\(tag) ×")
                }
                .buttonStyle(.plain)
                .help(L("Remove tag"))
            }

            Menu {
                if task.repeat == nil { Button(L("Repeat")) { popover = .repeat } }
                if task.remind == nil { Button(L("Reminder")) { popover = .remind } }
                Button(L("Tag")) { popover = .tag }
                if !model.showsSubtasks(task) { Button(L("Subtask")) { model.showSubtasks(task.id) } }
                Button(L("File or image…")) { importing = true }
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
                    Image(systemName: file.mime.hasPrefix("image/") ? "photo" : "doc")
                        .foregroundStyle(.secondary)
                    Button(file.name) {
                        if let path = file.localPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    }
                    .buttonStyle(.link)
                    .disabled(file.localPath == nil)
                    Text(file.localPath == nil ? L("downloads on the next sync") : ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
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
            }
        }
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
                    Button(L("Today")) { pick(days: 0) }
                    Button(L("Tomorrow")) { pick(days: 1) }
                    Button(L("In a week")) { pick(days: 7) }
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
                    Button(L("Remove"), role: .destructive) { apply(nil); dismiss() }
                }
                Spacer()
                Button(L("Done")) { apply(Moment.string(date, withTime: withTime)); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .fixedSize()
        .onAppear {
            withTime = timeRequired || value.map(Moment.hasTime) ?? false
            if let value, let parsed = Moment.date(value) {
                date = parsed
            } else if timeRequired {
                date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date().addingTimeInterval(86400)) ?? Date()
            }
        }
    }

    private func pick(days: Int) {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: Date())) ?? Date()
        let time = calendar.dateComponents([.hour, .minute], from: date)
        date = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
        apply(Moment.string(date, withTime: withTime))
        dismiss()
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
