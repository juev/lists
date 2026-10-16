import AppKit
import SwiftUI

/// The content of the main window: the large title, the task table (#308) and the footers of Trash and Completed.
struct TaskListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ViewTitle()
            if let error = model.startupError {
                ContentUnavailableView(L("The database could not be opened"), systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.sections.allSatisfy(\.tasks.isEmpty) && model.draft == nil {
                // R78: the events of the day are shown on a day without tasks as well.
                if model.eventsShown {
                    EventsBlock(events: model.dayEvents)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                }
                emptyState
            } else {
                TaskTable(
                    model: model,
                    rows: TaskTableRow.rows(model),
                    selected: Set(model.selectedIds),
                    lead: model.selection,
                    look: "\(model.rowSpacing) \(model.textScale) \(model.fontDesign)",
                    focusRequests: model.listFocusRequests,
                    titleFocus: model.titleFocus,
                    scope: model.scope,
                    attachmentsArrived: model.attachmentsArrived)
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

    @State private var confirmEmptyTrash = false
    @State private var clearCompleted: ClearCompleted?

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

