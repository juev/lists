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
                    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                        guard !typing else { return .ignored }
                        let step = press.key == .upArrow ? -1 : 1
                        // R117: with Shift the arrows grow and shrink the selection.
                        if press.modifiers.contains(.shift) { model.extendSelection(step) } else { model.moveSelection(step) }
                        return .handled
                    }
                    .onKeyPress(.return) {
                        guard !typing, let id = model.selection else { return .ignored }
                        // R117: several selected rows have no card to open.
                        if model.picked.isEmpty { model.toggleEditing(id) }
                        return .handled
                    }
                    .onKeyPress(.space) {
                        guard !typing, let task = model.selectedTask else { return .ignored }
                        if model.picked.isEmpty { model.toggleDone(task) } else { model.batch(.complete) }
                        return .handled
                    }
                    // A click inside an open card can leave the keyboard with the list: Esc still closes the card (R44).
                    // R117: with several rows selected Esc leaves one of them selected first.
                    .onKeyPress(.escape) {
                        guard !typing, model.clearPicked() || model.closeSelectedCard() else { return .ignored }
                        return .handled
                    }
                    .onDeleteCommand {
                        guard !typing else { return }
                        if model.picked.isEmpty { model.selectedTask.map(model.delete) } else { model.batch(.delete) }
                    }
                    // R117: ⌘A selects every row of the view; in a text field it belongs to the text.
                    .onCommand(#selector(NSResponder.selectAll(_:))) { if !typing { model.selectAll() } }
                    .onChange(of: model.selection) { _, new in
                        guard let new else { return }
                        if !typing { listFocused = true }
                        withAnimation { proxy.scrollTo(new) }
                    }
                    // A card is taller than the row it opens from: at the bottom of the window the rest of it would be
                    // out of sight. The list moves after the card has its height, which takes a turn or two (R38).
                    .onChange(of: model.expanded) { before, now in
                        guard let opened = now.subtracting(before).first else { return }
                        for wait in [0.0, 0.2] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                                guard model.expanded.contains(opened) else { return }
                                withAnimation { proxy.scrollTo(opened) }
                            }
                        }
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
        .background(KeyCatcher(handle: selectAll))
    }

    /// R117: ⌘A selects every row of the view. The Edit menu takes the press before the list does and hands selectAll:
    /// to the table the list is drawn with, which answers it by itself: `.onCommand` never hears it. So the press is
    /// caught before the menu; in a text field or a card it is left to them.
    private func selectAll(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command, event.keyCode == 0 || event.charactersIgnoringModifiers == "a", !typing else { return false }
        model.selectAll()
        return true
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
                // R123: the ids of the rows the drag carries, a line each.
                .draggable(model.dragIds(task.id).joined(separator: "\n")) {
                    DragPreview(title: task.title, count: model.dragIds(task.id).count)
                }
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

extension RowOrigin {
    /// The list in its colour; the project keeps the colour of the marks around it.
    var text: Text {
        let name = list.map { Text($0).foregroundStyle(color.flatMap { Color(hex: $0) } ?? .accentColor) }
        let rest = project.map { Text(list == nil ? $0 : " – \($0)") }
        switch (name, rest) {
        case (let name?, let rest?): return name + rest
        case (let name?, nil): return name
        case (nil, let rest?): return rest
        default: return Text("")
        }
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
            // R22: the subtasks a search found the task by; an open task shows all of its subtasks instead.
            if !isExpanded, let lines = model.found[task.id] {
                ForEach(lines, id: \.id) { SubtaskRow(task: $0, plain: true).padding(.leading, 22) }
            }
            if isExpanded {
                TaskEditor(task: task)
                    .padding(.leading, 34)
                subtasks
            }
        }
        // Rows set the font themselves: a List does not hand its environment font to them.
        .font(AppFont.style(.body))
        .contextMenu { RowMenuItems(items: menuItems) }
        // A task of a project inside the row of the project.
        .background { if depth > 0 { SubtaskMenuArea(items: { menuItems }) } }
        if isExpanded {
            content
                .onExitCommand { model.closeCard(task.id) }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .cardBackground()
                .background { CardArea(id: task.id) }
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
                    // The tasks of a project are full tasks with a card; a subtask is a line (R10).
                    if task.isProject {
                        TaskRow(task: child, depth: depth + 1).padding(.leading, 22)
                    } else {
                        SubtaskRow(task: child).padding(.leading, 22)
                    }
                }
                if !inTrash && !task.isLog {
                    SubtaskField(parent: task.id)
                        .padding(.leading, 34)
                }
            }
        }
    }

    private var header: some View {
        // R72: the mark stands in the middle of the height of the row, which has two lines where lists are mixed.
        // An open card keeps the mark at the first line of its title, which may take several (R73).
        HStack(alignment: isExpanded ? .firstTextBaseline : .center, spacing: 8) {
            TaskMark(task: task)

            // R72: the priority is a thin bar after the mark; its place is kept, so every title starts at one line.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Self.priorityBar(task.priority) ?? .clear)
                .frame(width: 3, height: !isExpanded && origin != nil ? 28 : 16)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + AppFont.native(.body).capHeight / 2 }
                .accessibilityLabel(task.priority.title)
                .accessibilityHidden(task.priority == .none)
            if task.isProject {
                Image(systemName: "folder").foregroundStyle(.secondary).accessibilityLabel(L("Project"))
            }
            if isExpanded && !inTrash && !task.isLog {
                TaskTitleField(task: task)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(task.title)
                            .font(AppFont.style(.body))
                            .strikethrough(task.done != nil)
                            .foregroundStyle(task.done != nil ? .secondary : .primary)
                            .lineLimit(1)
                        if !isExpanded { marks }
                    }
                    // R72: where lists are mixed the row says under the title which list the task is in, in the
                    // colour of the list, and a task of a project says whose it is (R31).
                    if !isExpanded, let origin {
                        origin.text.lineLimit(1).truncationMode(.tail).font(AppFont.style(.caption)).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 8)
            if !isExpanded, let date = Moment.rowDate(due: task.effectiveDue, open: task.done == nil, dayInHeading: dayInHeading) {
                // R125: a due date taken from the project is muted, with the project's mark before it.
                let inherited = task.due == nil
                HStack(spacing: 3) {
                    if inherited { Image(systemName: "folder").accessibilityLabel(L("Project")) }
                    Text(date.text).monospacedDigit()
                }
                .font(AppFont.style(.caption))
                .foregroundStyle(date.late ? AnyShapeStyle(.red) : inherited ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
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
                        // R122: as high as the text, so the spacing alone sets the height of the row.
                        .frame(width: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Expand"))
            }
        }
        .padding(.vertical, isExpanded ? 6 : RowSpacing.padding(model.rowSpacing))
        .padding(.horizontal, 6)
        // The selection is a strip behind a row; an open card is set apart by its outline instead.
        .background(
            model.isSelected(task.id) && !isExpanded ? Color.primary.opacity(0.07) : .clear,
            in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .background { RowClickArea(id: task.id) { model.toggleEditing(task.id) } }
    }

    /// Marks after the title, only for what is set, without text or numbers (R72).
    @ViewBuilder
    private var marks: some View {
        HStack(spacing: 6) {
            if task.repeat != nil { Image(systemName: "repeat").accessibilityLabel(L("Repeat")) }
            if !task.notes.isEmpty { Image(systemName: "text.alignleft").accessibilityLabel(L("Notes")) }
            if task.attachments > 0 { Image(systemName: "paperclip").accessibilityLabel(L("Attachments")) }
            if task.subtasksTotal > 0 { Image(systemName: "checklist").accessibilityLabel(L("Subtasks")) }
        }
        .font(AppFont.style(.caption))
        .foregroundStyle(.tertiary)
    }

    /// Whether the heading of the group already names the day of the due date.
    private var dayInHeading: Bool {
        switch model.effectiveScope {
        case .today: return task.effectiveDue.map { Moment.day($0) == Moment.today() } ?? false
        case .upcoming: return true
        default: return false
        }
    }

    /// In views that mix lists, say where the task lives.
    private var showsOrigin: Bool { depth == 0 && model.mixesLists }
    private var origin: RowOrigin? { showsOrigin ? model.origin(of: task) : nil }

    /// R72: the colour of the bar a row shows for the priority of its task; none for a task without one.
    static func priorityBar(_ priority: Priority) -> Color? {
        switch priority {
        case .high: .red
        case .medium: .orange
        case .low: .blue
        case .none: nil
        }
    }

    /// R117: the menu of a row that is one of several selected ones: the actions change all of them.
    /// Nil for a row that is not, which has the menu of its own.
    @MainActor
    static func batchItems(for task: TaskItem, _ model: AppModel) -> [RowMenuItem]? {
        guard model.picked.count > 1, model.picked.contains(task.id) else { return nil }
        let tasks = model.selectedTasks
        if tasks.allSatisfy(\.deleted) { return [RowMenuItem(title: L("Restore")) { model.batch(.restore) }] }
        if tasks.allSatisfy(\.isLog) { return [RowMenuItem(title: L("Delete records"), destructive: true) { model.batch(.delete) }] }
        func dates(_ action: @escaping (String) -> BatchAction) -> [RowMenuItem] {
            [(L("Today"), 0), (L("Tomorrow"), 1), (L("In a week"), 7)].map { title, days in
                RowMenuItem(title: title) { shiftDate(date: Moment.today(), days: Int64(days)).map { _ = model.batch(action($0)) } }
            }
        }
        var items = [
            RowMenuItem(title: L("Complete")) { model.batch(.complete) },
            RowMenuItem(title: L("Due"), children: dates { .due($0) }),
            RowMenuItem(title: L("Start"), children: dates { .start($0) }),
            RowMenuItem(title: L("Priority"), children: Priority.all.map { priority in
                RowMenuItem(title: priority.title) { model.batch(.priority(priority)) }
            }),
            RowMenuItem(title: L("Move to list"), children: moveItems(model, list: { list in
                RowMenuItem(title: model.listName(list)) { model.batch(.move(listId: list.id)) }
            }, project: { project in
                RowMenuItem(title: project.title) { model.batch(.project(id: project.id)) }
            })),
        ]
        items.append(RowMenuItem(title: L("Tag"), children: model.tags.map { tag in
            RowMenuItem(title: "#" + tag.name) { model.batch(.tag(tag.name)) }
        } + (model.tags.isEmpty ? [] : [.divider]) + [RowMenuItem(title: L("New tag…")) { model.askTagForSelection() }]))
        items.append(RowMenuItem(title: L("Won't do")) { model.batch(.wontDo) })
        items.append(.divider)
        items.append(RowMenuItem(title: L("Delete"), destructive: true) { model.batch(.delete) })
        return items
    }

    /// R129: the lists a task is moved to and, under them as a group of their own, the projects.
    @MainActor
    static func moveItems(_ model: AppModel, list: (TaskList) -> RowMenuItem, project: (TaskItem) -> RowMenuItem) -> [RowMenuItem] {
        let lists = model.lists.filter { !$0.archived }.map(list)
        guard !model.projects.isEmpty else { return lists }
        return lists + [.divider, RowMenuItem(title: L("Projects"), isHeader: true)] + model.projects.map(project)
    }

    /// The menu of the task. One description for both ways it is drawn: by SwiftUI for a row of
    /// the list and by AppKit for a subtask inside the row of its parent (`SubtaskMenuArea`).
    private var menuItems: [RowMenuItem] { Self.menuItems(for: task, model) }

    @MainActor
    static func menuItems(for task: TaskItem, _ model: AppModel) -> [RowMenuItem] {
        if let batch = batchItems(for: task, model) { return batch }
        if task.deleted {
            return [RowMenuItem(title: L("Restore")) { model.perform { try $0.restoreTask(id: task.id) } }]
        }
        if task.isLog {
            return [RowMenuItem(title: L("Delete record"), destructive: true) { model.delete(task) }]
        }
        var due = [
            RowMenuItem(title: L("Today")) { model.setDue(task, Moment.today()) },
            RowMenuItem(title: L("Tomorrow")) { model.setDue(task, shiftDate(date: Moment.today(), days: 1)) },
            RowMenuItem(title: L("In a week")) { model.setDue(task, shiftDate(date: Moment.today(), days: 7)) },
            RowMenuItem.divider,
            RowMenuItem(title: L("Choose…")) { if !model.expanded.contains(task.id) { model.toggleExpanded(task.id) } },
        ]
        if task.due != nil { due.append(RowMenuItem(title: L("Clear due date")) { model.setDue(task, nil) }) }
        var items = [
            RowMenuItem(title: L("Due"), children: due),
            RowMenuItem(title: L("Priority"), children: Priority.all.map { priority in
                // Through `batch`, as for several rows (R117): it registers the undo (#299).
                RowMenuItem(title: priority.title, on: task.priority == priority) {
                    model.batch(.priority(priority), ids: [task.id])
                }
            }),
            RowMenuItem(title: L("Move to list"), children: moveItems(model, list: { list in
                RowMenuItem(title: model.listName(list), disabled: task.parentId == nil && task.listId == list.id) {
                    model.batch(.move(listId: list.id), ids: [task.id])
                }
            }, project: { project in
                // R129: what a drop onto a project passes over (R123) is not offered.
                let refused = task.isProject || task.subtasksTotal > 0 || task.parentId == project.id
                return RowMenuItem(title: project.title, disabled: refused) {
                    model.batch(.project(id: project.id), ids: [task.id])
                }
            })),
            RowMenuItem(title: L("Add subtask")) { model.showSubtasks(task.id) },
        ]
        // R32: a project with tasks is not turned back; its tasks would become subtasks and lose their fields.
        if task.parentId == nil, !task.isProject || task.subtasksTotal == 0 {
            items.append(RowMenuItem(title: task.isProject ? L("Turn back into a task") : L("Make it a project")) {
                model.perform { try $0.setProject(id: task.id, project: !task.isProject) }
            })
        }
        items.append(RowMenuItem(title: L("Duplicate")) { model.perform { _ = try $0.duplicateTask(id: task.id) } })
        // R91: the files of the task, all of them, without looking for the menu of one.
        if task.attachments > 1 {
            items.append(RowMenuItem(title: L("Save All…")) { model.saveAllAttachments(of: task.id) })
        }
        if task.done == nil {
            items.append(RowMenuItem(title: L("Won't do")) { model.wontDo(task) })
        }
        items.append(.divider)
        items.append(RowMenuItem(title: L("Delete"), destructive: true) { model.delete(task) })
        return items
    }
}

/// The square mark of a task or of a subtask: a click completes it or takes it back into work.
struct TaskMark: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem

    var body: some View {
        Button {
            model.toggleDone(task)
        } label: {
            Image(systemName: task.wont ? "xmark.square.fill" : task.done != nil ? "checkmark.square.fill" : "square")
                // R94: the mark is as quiet as the icons of the fields; R72: a little smaller than the text.
                .font(AppFont.style(.callout))
                .fontWeight(.light)
                .foregroundStyle(task.done != nil ? .secondary : .tertiary)
        }
        .buttonStyle(.plain)
        // The mark is taller than a capital of the title: on the baseline it stands too high.
        // Its middle goes to the middle of a capital of the first line instead.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + AppFont.native(.body).capHeight / 2 }
        // The record of a repeat kept in a view of tasks takes its completion back (R128); in the journal it is history.
        .disabled(task.deleted || (task.isLog && (model.scope == .completed || model.scope == .wontDo)))
        .accessibilityLabel(task.done != nil ? L("Reopen") : L("Complete"))
    }
}

/// A subtask in the card of its task: a mark and a title, and no card of its own (R10, R38).
/// `plain` is the line under a task found by a search (R22): the mark and the title alone.
struct SubtaskRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    var plain = false

    private var locked: Bool { task.deleted || task.isLog }

    var body: some View {
        let line = HStack(alignment: .firstTextBaseline, spacing: 8) {
            TaskMark(task: task)
            if model.renaming == task.id {
                SubtaskTitleField(id: task.id)
            } else {
                Text(task.title)
                    .strikethrough(task.done != nil)
                    .foregroundStyle(task.done != nil ? .secondary : .primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .font(AppFont.style(.body))
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        if plain {
            line
        } else {
            line
                .background(
                    model.isSelected(task.id) ? Color.primary.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .background { RowClickArea(id: task.id) { if !locked { model.startRenaming(task) } } }
                .background { SubtaskMenuArea(items: { Self.menuItems(task, model) }) }
        }
    }

    /// The menu of a subtask: only what applies to it (R38).
    static func menuItems(_ task: TaskItem, _ model: AppModel) -> [RowMenuItem] {
        if let batch = TaskRow.batchItems(for: task, model) { return batch }
        if task.deleted {
            return [RowMenuItem(title: L("Restore")) { model.perform { try $0.restoreTask(id: task.id) } }]
        }
        if task.isLog {
            return [RowMenuItem(title: L("Delete record"), destructive: true) { model.delete(task) }]
        }
        var items = [
            RowMenuItem(title: L("Rename")) { model.startRenaming(task) },
            RowMenuItem(title: task.done != nil ? L("Reopen") : L("Complete")) { model.toggleDone(task) },
        ]
        if task.done == nil {
            items.append(RowMenuItem(title: L("Won't do")) { model.wontDo(task) })
        }
        items.append(RowMenuItem(title: L("Delete"), destructive: true) { model.delete(task) })
        return items
    }
}

/// The title of a subtask while it is edited in its line (R38): Return saves it, Esc leaves it as it was.
struct SubtaskTitleField: View {
    @Environment(AppModel.self) private var model
    let id: String
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        TextField(L("Title"), text: $model.renamingTitle)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { model.finishRenaming(id, save: true) }
            // Esc ends the edit and not the card of the task around the line.
            .onExitCommand { model.finishRenaming(id, save: false) }
            // On the next turn: the field is not in the table yet while it appears.
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onChange(of: focused) { _, now in if !now { model.finishRenaming(id, save: true) } }
            // R83: quitting does not take the keyboard from the title.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                model.finishRenaming(id, save: true)
            }
    }
}

/// An item of the menu of a task row.
struct RowMenuItem {
    var title = ""
    /// The check mark of an item that has one.
    var on: Bool?
    var disabled = false
    var destructive = false
    var isDivider = false
    /// The title of a group of the items that follow it.
    var isHeader = false
    /// The items of a submenu.
    var children: [RowMenuItem]?
    var action: () -> Void = {}

    static let divider = RowMenuItem(isDivider: true)
}

/// The items as the content of a SwiftUI menu.
struct RowMenuItems: View {
    let items: [RowMenuItem]

    var body: some View {
        ForEach(items.indices, id: \.self) { index in
            let item = items[index]
            if item.isDivider {
                Divider()
            } else if item.isHeader {
                Text(item.title)
            } else if let children = item.children {
                Menu(item.title) { RowMenuItems(items: children) }
            } else if let on = item.on {
                Toggle(item.title, isOn: Binding(get: { on }, set: { _ in item.action() }))
            } else {
                Button(item.title, role: item.destructive ? .destructive : nil, action: item.action)
                    .disabled(item.disabled)
            }
        }
    }
}

/// The place of a subtask, or of a task of a project, inside the row of its parent, for the right click (#201). SwiftUI gives
/// the context menu of a list row to the whole row: over a subtask it opened the menu of the task
/// the row belongs to, and "Won't do" or "Delete" chosen there went to that task. An AppKit view
/// under the subtask marks its place, and a right click there opens the menu of the subtask.
struct SubtaskMenuArea: NSViewRepresentable {
    let items: () -> [RowMenuItem]

    func makeNSView(context: Context) -> SubtaskMenuView { SubtaskMenuView() }

    func updateNSView(_ view: SubtaskMenuView, context: Context) { view.items = items }
}

final class SubtaskMenuView: NSView {
    var items: () -> [RowMenuItem] = { [] }
    private var actions: [() -> Void] = []

    private static let areas = NSHashTable<SubtaskMenuView>.weakObjects()
    private static var monitor: Any?

    /// The view marks a place and takes nothing from the pointer: clicks go to the row over it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            Self.areas.remove(self)
        } else {
            Self.areas.add(self)
            Self.watch()
        }
    }

    /// The subtask a right click at a point of the window is for: the innermost one when subtasks
    /// are nested. None when the click lands on text or on a file, which have menus of their own,
    /// or on something outside the row of the subtask, such as a toolbar the list has scrolled under.
    static func area(at point: NSPoint, in window: NSWindow) -> SubtaskMenuView? {
        guard let hit = (window.contentView?.superview ?? window.contentView)?.hitTest(point),
              let area = areas.allObjects
                .filter({ $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: nil).contains(point) })
                .min(by: { $0.bounds.height < $1.bounds.height })
        else { return nil }
        var row: NSView? = area
        while let current = row, !(current is NSTableRowView) { row = current.superview }
        guard let row, hit.isDescendant(of: row) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== row {
            if current is NSText || current is FilePointerView { return nil }
            view = current.superview
        }
        return area
    }

    /// The menu of the subtask, built from the same items as the menu of a row of the list.
    func subtaskMenu() -> NSMenu {
        actions = []
        return menu(of: items())
    }

    private func menu(of items: [RowMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.isDivider {
                menu.addItem(.separator())
                continue
            }
            if item.isHeader {
                menu.addItem(.sectionHeader(title: item.title))
                continue
            }
            let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            if let children = item.children {
                entry.submenu = self.menu(of: children)
            } else {
                entry.action = #selector(run(_:))
                entry.target = self
                entry.tag = actions.count
                actions.append(item.action)
                entry.state = item.on == true ? .on : .off
                entry.isEnabled = !item.disabled
            }
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func run(_ item: NSMenuItem) {
        if actions.indices.contains(item.tag) { actions[item.tag]() }
    }

    /// Right clicks and ⌃clicks are looked at before the list gets them.
    private static func watch() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  let window = event.window, let area = area(at: event.locationInWindow, in: window)
            else { return event }
            NSMenu.popUpContextMenu(area.subtaskMenu(), with: event, for: area)
            return nil
        }
    }
}

/// The place of a row, or of a subtask inside the row of its parent, for the clicks of R117 (#300). Tap gestures on a row
/// took the mouse from the list: neither a drag onto the sidebar (R123) nor a reorder started. An AppKit view under the
/// row marks its place and takes nothing from the pointer, and the click counts only when the button went up where it
/// went down: a drag changes no selection.
struct RowClickArea: NSViewRepresentable {
    let id: String
    /// What a double click does.
    let double: () -> Void

    func makeNSView(context: Context) -> RowClickView { RowClickView() }

    func updateNSView(_ view: RowClickView, context: Context) {
        view.id = id
        view.double = double
    }
}

final class RowClickView: NSView {
    var id = ""
    var double: () -> Void = {}

    private static let areas = NSHashTable<RowClickView>.weakObjects()
    private static var monitor: Any?

    /// The view marks a place and takes nothing from the pointer: clicks go to the row over it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            Self.areas.remove(self)
        } else {
            Self.areas.add(self)
            Self.watch()
        }
    }

    /// The row a click at a point of the window is for: the innermost one, a subtask before the row of its parent.
    /// None when the click lands on text or on a file, which take clicks of their own, or outside the row.
    static func area(at point: NSPoint, in window: NSWindow) -> RowClickView? {
        guard let hit = (window.contentView?.superview ?? window.contentView)?.hitTest(point),
              let area = areas.allObjects
                .filter({ $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: nil).contains(point) })
                .min(by: { $0.bounds.height < $1.bounds.height })
        else { return nil }
        var row: NSView? = area
        while let current = row, !(current is NSTableRowView) { row = current.superview }
        guard let row, hit.isDescendant(of: row) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== row {
            if current is NSText || current is FilePointerView { return nil }
            view = current.superview
        }
        return area
    }

    /// Presses are looked at before the list gets them, and passed on. The release of the button never comes here:
    /// the list follows the mouse in a loop of its own until then (seen in a probe, #300). So the click is taken once
    /// that loop is over and the default mode of the run loop runs again: with the button up near the place it went
    /// down, it was a click; with the button still down or the pointer gone, a drag began and the selection stays.
    private static func watch() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            // ⌃click opens the menu of the row.
            guard !event.modifierFlags.contains(.control), let window = event.window,
                  let area = area(at: event.locationInWindow, in: window)
            else { return event }
            let id = area.id
            let flags = event.modifierFlags
            let count = event.clickCount
            let down = NSEvent.mouseLocation
            RunLoop.main.perform(inModes: [.default]) {
                let up = NSEvent.mouseLocation
                guard NSEvent.pressedMouseButtons & 1 == 0, hypot(up.x - down.x, up.y - down.y) < 4 else { return }
                MainActor.assumeIsolated {
                    AppModel.shared.click(id, command: flags.contains(.command), shift: flags.contains(.shift))
                    if count == 2 { area.double() }
                }
            }
            return event
        }
    }
}

/// The place of an open card, for the click outside it that closes it (R44). SwiftUI tells a click on a view, not a click
/// that missed one: the empty space of the list, the title of the view, the sidebar and the toolbar get none of it.
struct CardArea: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> CardAreaView { CardAreaView() }

    func updateNSView(_ view: CardAreaView, context: Context) { view.id = id }
}

final class CardAreaView: NSView {
    var id = ""

    private static let areas = NSHashTable<CardAreaView>.weakObjects()
    private static var monitor: Any?

    /// The view marks a place and takes nothing from the pointer: clicks go to the card over it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            Self.areas.remove(self)
        } else {
            Self.areas.add(self)
            Self.watch()
        }
    }

    /// Looks at a click in a window with open cards and closes those it missed. A click on another row of the list is
    /// left to the list, which selects that row and closes the card itself (R38): closing it here first would move the
    /// rows under a drag that starts there. A click on the scroller only scrolls. Popovers of a card, Quick Look and
    /// menus are windows of their own, so a click there is not in the window of the card.
    static func clicked(at point: NSPoint, in window: NSWindow) {
        let open = areas.allObjects.filter {
            $0.window === window && !$0.isHiddenOrHasHiddenAncestor && AppModel.shared.expanded.contains($0.id)
        }
        guard let table = open.lazy.compactMap(\.table).first,
              let hit = (window.contentView?.superview ?? window.contentView)?.hitTest(point)
        else { return }
        var row: NSView? = hit
        while let current = row, !(current is NSTableRowView) { row = current.superview }
        if let row, row.isDescendant(of: table) { return }
        var view: NSView? = hit
        while let current = view {
            if current is NSScroller { return }
            view = current.superview
        }
        // The keyboard stays where the click puts it: in the sidebar, in a text field, in the list itself.
        var keyboardToList = true
        view = hit
        while let current = view {
            if current is NSTableView || current is NSTextField || current is NSText { keyboardToList = false }
            view = current.superview
        }
        for area in open where !area.convert(area.bounds, to: nil).contains(point) {
            AppModel.shared.closeCardByClick(area.id, keyboardToList: keyboardToList)
        }
    }

    /// The table of the list the card is drawn in.
    private var table: NSTableView? {
        var view = superview
        while let current = view, !(current is NSTableView) { view = current.superview }
        return view as? NSTableView
    }

    /// Clicks are looked at before the views under them get them, and passed on.
    private static func watch() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if let window = event.window { clicked(at: event.locationInWindow, in: window) }
            return event
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

/// R123: what follows the pointer: the title of the row the drag started on and, for several tasks, their number.
struct DragPreview: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1).font(AppFont.style(.body))
            if count > 1 {
                Text("\(count)")
                    .font(AppFont.style(.caption, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 280, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
    }
}
