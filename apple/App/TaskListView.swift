import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskListView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var listFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if model.draft != nil {
                DraftEditor(
                    draft: Binding(get: { model.draft ?? TaskDraft() }, set: { if model.draft != nil { model.draft = $0 } }),
                    onClose: { model.draft = nil })
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .cardBackground()
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
            }
            if let error = model.startupError {
                ContentUnavailableView(L("The database could not be opened"), systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.sections.allSatisfy(\.tasks.isEmpty) {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(model.sections) { section in
                            if let title = section.title {
                                Section(title) { rows(section) }
                            } else {
                                rows(section)
                            }
                        }
                    }
                    .listStyle(.inset)
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
                        model.toggleExpanded(id)
                        return .handled
                    }
                    .onKeyPress(.space) {
                        guard !typing, let task = model.selectedTask else { return .ignored }
                        model.toggleDone(task)
                        return .handled
                    }
                    .onDeleteCommand { if !typing { model.selectedTask.map(model.delete) } }
                    .onChange(of: model.selection) { _, new in
                        guard let new else { return }
                        if !typing { listFocused = true }
                        withAnimation { proxy.scrollTo(new) }
                    }
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
        }
        .confirmationDialog(L("Delete everything in the trash for good?"), isPresented: $confirmEmptyTrash) {
            Button(L("Empty Trash"), role: .destructive) { model.perform { _ = try $0.emptyTrash() } }
        } message: {
            Text(L("This cannot be undone."))
        }
    }

    /// True while a text view or the field editor of a text field has the keyboard.
    private var typing: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    @State private var confirmEmptyTrash = false

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
            case .completed: return (L("Nothing completed yet"), "checkmark.circle", "")
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

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            if !text.isEmpty { Text(text) }
        }
        .font(AppFont.style(.caption))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
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
                Divider().padding(.leading, 34)
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
                .padding(.horizontal, 4)
                .padding(.top, 4)
                .padding(.bottom, 10)
                .cardBackground()
                .padding(.vertical, 4)
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
                Image(systemName: task.done != nil ? "checkmark.circle.fill" : "circle")
                    .font(AppFont.style(.title3))
                    .foregroundStyle(task.done != nil ? Color.secondary : (model.list(task.listId)?.tint ?? .accentColor))
            }
            .buttonStyle(.plain)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(AppFont.style(.body))
                        .strikethrough(task.done != nil)
                        .foregroundStyle(task.done != nil ? .secondary : .primary)
                        .lineLimit(2)
                    if !isExpanded { summary }
                }
            }
            Spacer(minLength: 8)
            Button {
                model.selection = task.id
                model.toggleExpanded(task.id)
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(AppFont.style(.caption))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? L("Collapse") : L("Expand"))
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            model.selection == task.id ? Color.primary.opacity(0.07) : .clear,
            in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.toggleExpanded(task.id) }
        .simultaneousGesture(TapGesture().onEnded { model.selection = task.id })
    }

    /// One line under the title: only what is set.
    @ViewBuilder
    private var summary: some View {
        let hasAny = task.due != nil || task.start != nil || task.repeat != nil || !task.tags.isEmpty
            || task.subtasksTotal > 0 || task.attachments > 0 || !task.notes.isEmpty || showsOrigin
        if hasAny {
            HStack(spacing: 8) {
                if let start = task.start {
                    Label(L("from ") + Moment.label(start).lowercased(), systemImage: "calendar.badge.clock")
                }
                if let due = task.due {
                    Label(Moment.label(due), systemImage: "calendar")
                        .foregroundStyle(task.done == nil && Moment.isOverdue(due) ? .red : .secondary)
                }
                if task.repeat != nil { Image(systemName: "repeat") }
                if task.subtasksTotal > 0 {
                    Label("\(task.subtasksDone)/\(task.subtasksTotal)", systemImage: "checklist")
                }
                if task.attachments > 0 { Label("\(task.attachments)", systemImage: "paperclip") }
                if !task.notes.isEmpty { Image(systemName: "text.alignleft") }
                ForEach(task.tags, id: \.self) { Text("#\($0)") }
                if showsOrigin { Text(origin).lineLimit(1) }
            }
            .font(AppFont.style(.caption))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
    }

    /// In views that mix lists, say where the task lives.
    private var showsOrigin: Bool {
        if depth > 0 { return false }
        switch model.effectiveScope {
        case .today, .upcoming, .tag, .search, .completed, .trash, .filter: return true
        default: return false
        }
    }

    private var origin: String {
        let list = model.list(task.listId).map(model.listName) ?? ""
        if let parent = task.parentTitle { return "\(list) › \(parent)" }
        return list
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

extension View {
    /// The outline that sets an open task apart from the rows around it.
    func cardBackground() -> some View {
        background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.14))
        }
    }
}
