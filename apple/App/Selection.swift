import Foundation

/// R117: one action on all the selected tasks.
enum BatchAction {
    case complete, wontDo, delete, restore
    case due(String), start(String)
    case priority(Priority)
    case move(listId: String)
    /// R123, R129: into a project, at its end.
    case project(id: String)
    case tag(String)

    /// Whether the action applies to this task; one it does not apply to is passed over.
    /// A subtask has a title only (R10): it is completed, closed and deleted, and nothing else.
    func applies(to task: TaskItem, subtask: Bool) -> Bool {
        // A task in the trash is only restored, and a record of a completed occurrence only deleted.
        if task.deleted { if case .restore = self { return true } else { return false } }
        if task.isLog { if case .delete = self { return true } else { return false } }
        switch self {
        case .complete, .wontDo: return task.done == nil
        case .delete: return true
        case .restore: return false
        case .due(let value): return !subtask && task.due != value
        case .start(let value): return !subtask && task.start != value
        case .priority(let value): return !subtask && task.priority != value
        case .move(let listId): return !(subtask || (task.parentId == nil && task.listId == listId))
        case .project(let id):
            // A project and a task with lines under it stay at the top level (R10).
            return !(subtask || task.id == id || task.parentId == id || task.isProject || task.subtasksTotal > 0)
        case .tag(let name): return !(subtask || name.isEmpty || task.tags.contains(name))
        }
    }

    func run(_ store: Store, _ id: String) throws {
        switch self {
        case .complete: _ = try store.completeTask(id: id)
        case .wontDo: _ = try store.wontDoTask(id: id)
        case .delete: try store.deleteTask(id: id)
        case .restore: try store.restoreTask(id: id)
        case .due(let value): try store.setDue(id: id, due: value)
        case .start(let value): try store.setStart(id: id, start: value)
        case .priority(let value): try store.setPriority(id: id, priority: value)
        case .move(let listId): try store.moveToList(id: id, listId: listId)
        case .project(let project): try store.moveToProject(id: id, projectId: project)
        case .tag(let name): try store.addTag(id: id, tag: name)
        }
    }

    /// The name of the action in the Edit menu, after "Undo".
    var name: String {
        switch self {
        case .complete: L("Complete Task")
        case .wontDo: L("Won't do")
        case .delete: L("Delete Task")
        default: L("Change Tasks")
        }
    }
}
