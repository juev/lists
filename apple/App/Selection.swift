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

    /// How the change an action made to one task is taken back.
    enum Back {
        case reopen, restore, delete
        case due(String?), start(String?)
        case priority(Priority)
        case place(listId: String, parentId: String?)
        case untag(String)
    }

    /// What an action does to one task; `back` is nil when the change cannot be taken back.
    struct Step { let back: Back? }

    /// The step of the action for this task, or nil when the action does not apply to it and the task is passed over.
    /// A subtask has a title only (R10): it is completed, closed and deleted, and nothing else.
    func step(for task: TaskItem, subtask: Bool) -> Step? {
        // A task in the trash is only restored, and a record of a completed occurrence only deleted.
        if task.deleted { if case .restore = self { return Step(back: .delete) } else { return nil } }
        if task.isLog { if case .delete = self { return Step(back: .restore) } else { return nil } }
        switch self {
        case .complete, .wontDo:
            if task.done != nil { return nil }
            // A repeating task that moved on gets its dates back the same way (R128).
            return Step(back: .reopen)
        case .delete: return Step(back: .restore)
        case .restore: return nil
        case .due(let value): return subtask || task.due == value ? nil : Step(back: .due(task.due))
        case .start(let value): return subtask || task.start == value ? nil : Step(back: .start(task.start))
        case .priority(let value): return subtask || task.priority == value ? nil : Step(back: .priority(task.priority))
        case .move(let listId):
            return subtask || (task.parentId == nil && task.listId == listId) ? nil : Step(back: .place(listId: task.listId, parentId: task.parentId))
        case .project(let id):
            // A project and a task with lines under it stay at the top level (R10).
            let stays = subtask || task.id == id || task.parentId == id || task.isProject || task.subtasksTotal > 0
            return stays ? nil : Step(back: .place(listId: task.listId, parentId: task.parentId))
        case .tag(let name): return subtask || name.isEmpty || task.tags.contains(name) ? nil : Step(back: .untag(name))
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

extension BatchAction.Back {
    func run(_ store: Store, _ id: String) throws {
        switch self {
        // With the subtasks the action closed along with the task.
        case .reopen: try store.undoCloseTask(id: id)
        case .restore: try store.restoreTask(id: id)
        case .delete: try store.deleteTask(id: id)
        case .due(let value): try store.setDue(id: id, due: value)
        case .start(let value): try store.setStart(id: id, start: value)
        case .priority(let value): try store.setPriority(id: id, priority: value)
        // The former place among its neighbours is not kept: the task comes first.
        case .place(let listId, let parentId): try store.moveTask(id: id, listId: listId, parentId: parentId, after: nil)
        case .untag(let name): try store.removeTag(id: id, tag: name)
        }
    }
}
