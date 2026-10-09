import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskListView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var listFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ViewTitle()
            if model.draft != nil {
                DraftEditor(
                    draft: Binding(get: { model.draft ?? TaskDraft() }, set: { if model.draft != nil { model.draft = $0 } }),
                    onClose: { model.draft = nil })
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .cardBackground()
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }
            if let error = model.startupError {
                ContentUnavailableView(L("The database could not be opened"), systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.sections.allSatisfy(\.tasks.isEmpty) {
                // R78: the events of the day are shown on a day without tasks as well.
                if model.eventsShown {
                    EventsBlock(events: model.dayEvents)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                }
                emptyState
            } else {
                ScrollViewReader { proxy in
                    List {
                        if model.eventsShown {
                            EventsBlock(events: model.dayEvents)
                                .listRowSeparator(.hidden)
                        } else if model.visibleSections.first?.title == nil {
                            // #155: the first row of the list keeps the height it was first given, so a card
                            // in it that grows is cut off at the bottom. An empty row takes that place.
                            // A view that starts with the heading of a group has that heading there.
                            Color.clear
                                .frame(height: 1)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .accessibilityHidden(true)
                        }
                        ForEach(model.visibleSections) { section in
                            if let title = section.title {
                                Section(title) { rows(section) }
                            } else {
                                rows(section)
                            }
                        }
                    }
                    .listStyle(.inset)
                    // The rows are as high as what they hold; without this the empty first row would take a line.
                    .environment(\.defaultMinListRowHeight, 1)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($listFocused)
                    // The keys below drive the list; while a text field inside a
                    // row has the keyboard they belong to the text.
                    .onKeyPress(.upArrow) {
                        guard !typing else { return .ignored }
                        model.moveSelection(-1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !typing else { return .ignored }
                        model.moveSelection(1)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        guard !typing, let id = model.selection else { return .ignored }
                        model.toggleEditing(id)
                        return .handled
                    }
                    .onKeyPress(.space) {
                        guard !typing, let task = model.selectedTask else { return .ignored }
                        model.toggleDone(task)
                        return .handled
                    }
                    // A click inside an open card can leave the keyboard with the list: Esc still closes the card (R44).
                    .onKeyPress(.escape) {
                        guard !typing, model.closeSelectedCard() else { return .ignored }
                        return .handled
                    }
                    .onDeleteCommand { if !typing { model.selectedTask.map(model.delete) } }
                    .onChange(of: model.selection) { _, new in
                        guard let new else { return }
                        if !typing { listFocused = true }
                        withAnimation { proxy.scrollTo(new) }
                    }
                    .onChange(of: model.listFocusRequests) { _, _ in listFocused = true }
                }
            }
            if case .trash = model.effectiveScope {
                Divider()
                HStack {
                    Spacer()
                    Button(L("Empty Trash…"), role: .destructive) { confirmEmptyTrash = true }
                }
                .padding(10)
            }
            if case .completed = model.effectiveScope, !model.sections.allSatisfy(\.tasks.isEmpty) {
                Divider()
                HStack {
                    Spacer()
                    Menu(L("Clear…")) {
                        ForEach(ClearCompleted.allCases, id: \.self) { choice in
                            Button(choice.title) { clearCompleted = choice }
                        }
                    }
                    .fixedSize()
                }
                .padding(10)
            }
        }
        .confirmationDialog(L("Delete everything in the trash for good?"), isPresented: $confirmEmptyTrash) {
            Button(L("Empty Trash"), role: .destructive) { model.perform { _ = try $0.emptyTrash() } }
        } message: {
            Text(L("This cannot be undone."))
        }
        // Clearing bypasses the trash, so it is confirmed like emptying the trash (R46).
        .confirmationDialog(
            clearCompleted?.question ?? "",
            isPresented: Binding(get: { clearCompleted != nil }, set: { if !$0 { clearCompleted = nil } }),
            presenting: clearCompleted
        ) { choice in
            Button(L("Clear"), role: .destructive) { model.perform { _ = try $0.clearCompleted(before: choice.before) } }
        } message: { _ in
            Text(L("This cannot be undone."))
        }
    }

    /// True while a text view, the field editor of a text field, a chip of a card or the row of a file in it has the keyboard.
    private var typing: Bool { Keyboard.text != nil || Keyboard.inCard }

    @State private var confirmEmptyTrash = false
    @State private var clearCompleted: ClearCompleted?

    @ViewBuilder
    private func rows(_ section: TaskSection) -> some View {
        let each = ForEach(section.tasks, id: \.id) { task in
            TaskRow(task: task, depth: 0)
                .listRowSeparator(.hidden)
                .draggable(task.id)
        }
        if model.canReorder {
            each.onMove { model.move(from: $0, to: $1) }
        } else {
            each
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let (title, symbol, text): (String, String, String) = {
            switch model.effectiveScope {
            case .today: return (L("All done for today"), "sun.max", L("Tasks due today will show up here."))
            case .inbox: return (L("Inbox is empty"), "tray", L("Everything without a list lands here."))
            case .upcoming: return (L("Nothing scheduled"), "calendar", L("Tasks with a future date will show up here."))
            case .completed: return (L("Nothing completed yet"), "checkmark.square", "")
            case .wontDo: return (L("No tasks marked won't do"), "xmark.square", "")
            case .trash: return (L("Trash is empty"), "trash", "")
            case .search: return (L("Nothing found"), "magnifyingglass", "")
            default: return (L("No tasks"), "checklist", L("Press ⌘N to add a task."))
            }
        }()
        ContentUnavailableView(title, systemImage: symbol, description: Text(text))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What the quick-entry parser recognised in the line being typed.
struct QuickChips: View {
    @Environment(AppModel.self) private var model
    let text: String

    var body: some View {
        if let parsed = model.store?.parseQuick(text: text), !text.isEmpty {
            HStack(spacing: 4) {
                if let due = parsed.due { Chip(symbol: "calendar", text: Moment.label(due)) }
                if parsed.priority != .none { Chip(symbol: nil, text: parsed.priority.marks, tint: .orange) }
                ForEach(parsed.tags, id: \.self) { Chip(symbol: nil, text: "#\($0)") }
                if let list = parsed.listName { Chip(symbol: "list.bullet", text: list) }
            }
        }
    }
}

struct Chip: View {
    var symbol: String?
    var text: String
    var tint: Color = .secondary
    /// A field that is not set: the icon alone, larger, thin and light, without the capsule (R82).
    var plain = false

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).fontWeight(plain ? .light : nil) }
            if !text.isEmpty { Text(text) }
        }
        .font(AppFont.style(plain ? .body : .caption))
        .foregroundStyle(plain ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(plain ? 0 : 0.12), in: Capsule())
        .lineLimit(1)
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    let depth: Int

    private var isExpanded: Bool { model.expanded.contains(task.id) }
    private var inTrash: Bool { task.deleted }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 6) {
            header
            if isExpanded {
                TaskEditor(task: task)
                    .padding(.leading, 34)
                subtasks
            }
        }
        // Rows set the font themselves: a List does not hand its environment font to them.
        .font(AppFont.style(.body))
        .contextMenu { menu }
        if isExpanded {
            content
                .onExitCommand { model.closeCard(task.id) }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .cardBackground()
                .padding(.vertical, 8)
        } else {
            content
        }
    }

    /// Subtasks stay folded behind one line until asked for; a task without
    /// any does not mention them at all.
    @ViewBuilder
    private var subtasks: some View {
        let shown = model.showsSubtasks(task)
        if task.subtasksTotal > 0 || shown {
            Button {
                model.toggleSubtasks(task.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: shown ? "chevron.down" : "chevron.right").frame(width: 12)
                    Text(L("Subtasks"))
                    if task.subtasksTotal > 0 { Text("\(task.subtasksDone)/\(task.subtasksTotal)").monospacedDigit() }
                }
                .font(AppFont.style(.caption))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 34)
            .disabled(task.isProject)
            if shown {
                ForEach(model.children[task.id] ?? [], id: \.id) { child in
                    TaskRow(task: child, depth: depth + 1)
                        .padding(.leading, 22)
                }
                if !inTrash && !task.isLog {
                    SubtaskField(parent: task.id)
                        .padding(.leading, 34)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                model.toggleDone(task)
            } label: {
                Image(systemName: task.wont ? "xmark.square.fill" : task.done != nil ? "checkmark.square.fill" : "square")
                    // R94: the mark is as high as the text and as quiet as the icons of the fields.
                    .font(AppFont.style(.body))
                    .fontWeight(.light)
                    .foregroundStyle(task.done != nil ? .secondary : .tertiary)
            }
            .buttonStyle(.plain)
            // The mark is taller than a capital of the title: on the baseline it stands too high.
            // Its middle goes to the middle of a capital of the first line instead.
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + AppFont.native(.body).capHeight / 2 }
            .disabled(task.isLog || inTrash)
            .accessibilityLabel(task.done != nil ? L("Reopen") : L("Complete"))

            if task.isProject {
                Image(systemName: "folder").foregroundStyle(.secondary).accessibilityLabel(L("Project"))
            }
            if task.priority != .none {
                Text(task.priority.marks).font(AppFont.style(.body, weight: .bold)).foregroundStyle(.orange)
                    .accessibilityLabel(task.priority.title)
            }
            if isExpanded && !inTrash && !task.isLog {
                TaskTitleField(task: task)
            } else {
                Text(task.title)
                    .font(AppFont.style(.body))
                    .strikethrough(task.done != nil)
                    .foregroundStyle(task.done != nil ? .secondary : .primary)
                    .lineLimit(1)
                if !isExpanded { marks }
            }
            Spacer(minLength: 8)
            if !isExpanded, let date = Moment.rowDate(due: task.due, open: task.done == nil, dayInHeading: dayInHeading) {
                Text(date.text)
                    .font(AppFont.style(.caption))
                    .monospacedDigit()
                    .foregroundStyle(date.late ? .red : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            // R94: an open card has no chevron; a key or another task closes it.
            if !isExpanded {
                Button {
                    model.selection = task.id
                    model.toggleExpanded(task.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(AppFont.style(.caption))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Expand"))
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        // The selection is a strip behind a row; an open card is set apart by its outline instead.
        .background(
            model.selection == task.id && !isExpanded ? Color.primary.opacity(0.07) : .clear,
            in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.toggleEditing(task.id) }
        .simultaneousGesture(TapGesture().onEnded { model.selection = task.id })
    }

    /// Marks after the title, only for what is set, without text or numbers (R72).
    @ViewBuilder
    private var marks: some View {
        HStack(spacing: 6) {
            if task.repeat != nil { Image(systemName: "repeat").accessibilityLabel(L("Repeat")) }
            if !task.notes.isEmpty { Image(systemName: "text.alignleft").accessibilityLabel(L("Notes")) }
            if task.attachments > 0 { Image(systemName: "paperclip").accessibilityLabel(L("Attachments")) }
            if task.subtasksTotal > 0 { Image(systemName: "checklist").accessibilityLabel(L("Subtasks")) }
            // A subtask shown on its own says whose it is (R12).
            if showsOrigin, let parent = task.parentTitle { Text(parent).lineLimit(1) }
        }
        .font(AppFont.style(.caption))
        .foregroundStyle(.tertiary)
    }

    /// Whether the heading of the group already names the day of the due date.
    private var dayInHeading: Bool {
        switch model.effectiveScope {
        case .today: return task.due.map { Moment.day($0) == Moment.today() } ?? false
        case .upcoming: return true
        default: return false
        }
    }

    /// In views that mix lists, say where the task lives.
    private var showsOrigin: Bool {
        if depth > 0 { return false }
        switch model.effectiveScope {
        case .today, .upcoming, .tag, .search, .completed, .wontDo, .trash, .filter: return true
        default: return false
        }
    }

    @ViewBuilder
    private var menu: some View {
        if inTrash {
            Button(L("Restore")) { model.perform { try $0.restoreTask(id: task.id) } }
        } else if task.isLog {
            Button(L("Delete record"), role: .destructive) { model.delete(task) }
        } else {
            Menu(L("Due")) {
                Button(L("Today")) { model.setDue(task, Moment.today()) }
                Button(L("Tomorrow")) { model.setDue(task, shiftDate(date: Moment.today(), days: 1)) }
                Button(L("In a week")) { model.setDue(task, shiftDate(date: Moment.today(), days: 7)) }
                Divider()
                Button(L("Choose…")) { if !isExpanded { model.toggleExpanded(task.id) } }
                if task.due != nil { Button(L("Clear due date")) { model.setDue(task, nil) } }
            }
            Menu(L("Priority")) {
                ForEach(Priority.all, id: \.self) { priority in
                    Toggle(priority.title, isOn: Binding(
                        get: { task.priority == priority },
                        set: { _ in model.perform { try $0.setPriority(id: task.id, priority: priority) } }))
                }
            }
            Menu(L("Move to list")) {
                ForEach(model.lists.filter { !$0.archived }, id: \.id) { list in
                    Button(model.listName(list)) { model.perform { try $0.moveToList(id: task.id, listId: list.id) } }
                        .disabled(task.parentId == nil && task.listId == list.id)
                }
            }
            Button(L("Add subtask")) { model.showSubtasks(task.id) }
            if task.parentId == nil {
                Button(task.isProject ? L("Turn back into a task") : L("Make it a project")) {
                    model.perform { try $0.setProject(id: task.id, project: !task.isProject) }
                }
            }
            Button(L("Duplicate")) { model.perform { _ = try $0.duplicateTask(id: task.id) } }
            // R91: the files of the task, all of them, without looking for the menu of one.
            if task.attachments > 1 {
                Button(L("Save All…")) { model.saveAllAttachments(of: task.id) }
            }
            if task.done == nil {
                Button(L("Won't do")) { model.wontDo(task) }
            }
            Divider()
            Button(L("Delete"), role: .destructive) { model.delete(task) }
        }
    }
}

struct SubtaskField: View {
    @Environment(AppModel.self) private var model
    let parent: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle").foregroundStyle(.tertiary)
            TextField(L("Subtask"), text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    if model.add(text, parent: parent) != nil { text = "" }
                    focused = true
                }
        }
        .font(AppFont.style(.callout))
    }
}

@MainActor
enum Keyboard {
    /// The text being typed into: a text view, or the field editor of a text field.
    static var text: NSText? {
        #if DEBUG
        let window = NSApp.keyWindow ?? DebugScript.backgroundWindow
        #else
        let window = NSApp.keyWindow
        #endif
        return window?.firstResponder as? NSText
    }

    /// The cards one of whose chips (R62) or files (R54) has the keyboard: the keyboard moving
    /// from a card to another is reported by both, in no set order.
    static var cards: Set<String> = []
    static var inCard: Bool { !cards.isEmpty }
}

extension View {
    /// The outline that sets an open task apart from the rows around it.
    func cardBackground() -> some View {
        background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
                .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
            // Barely there in the light appearance; in the dark one it is what tells the card from the window.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05))
        }
    }
}

/// What "Clear…" in Completed removes.
enum ClearCompleted: CaseIterable {
    case olderThanMonth, olderThanYear, everything

    var title: String {
        switch self {
        case .olderThanMonth: return L("Older than a month")
        case .olderThanYear: return L("Older than a year")
        case .everything: return L("Everything")
        }
    }

    var question: String {
        switch self {
        case .olderThanMonth: return L("Delete completed tasks older than a month for good?")
        case .olderThanYear: return L("Delete completed tasks older than a year for good?")
        case .everything: return L("Delete all completed tasks for good?")
        }
    }

    /// Tasks completed before this day go; nil removes all of them.
    var before: String? {
        let months: Int
        switch self {
        case .olderThanMonth: months = 1
        case .olderThanYear: months = 12
        case .everything: return nil
        }
        return Calendar.current.date(byAdding: .month, value: -months, to: Date()).map { Moment.string($0, withTime: false) }
    }
}
