import AppKit

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

/// A menu of AppKit built from the items of the menu of a task, which keeps the actions of its items.
@MainActor
final class RowMenu: NSObject {
    private var actions: [() -> Void] = []

    func menu(_ items: [RowMenuItem]) -> NSMenu {
        actions = []
        return build(items)
    }

    private func build(_ items: [RowMenuItem]) -> NSMenu {
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
                entry.submenu = build(children)
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
}

/// The menus of the rows of the task list: of a task, of several selected rows (R117) and of a subtask (R38).
@MainActor
enum TaskMenus {
    /// R117: the menu of a row that is one of several selected ones: the actions change all of them.
    /// Nil for a row that is not, which has the menu of its own.
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
    static func moveItems(_ model: AppModel, list: (TaskList) -> RowMenuItem, project: (TaskItem) -> RowMenuItem) -> [RowMenuItem] {
        let lists = model.lists.filter { !$0.archived }.map(list)
        guard !model.projects.isEmpty else { return lists }
        return lists + [.divider, RowMenuItem(title: L("Projects"), isHeader: true)] + model.projects.map(project)
    }

    /// The menu of a task, or of the several selected rows it is one of.
    static func taskItems(for task: TaskItem, _ model: AppModel) -> [RowMenuItem] {
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

    /// The menu of a subtask: only what applies to it (R38).
    static func subtaskItems(_ task: TaskItem, _ model: AppModel) -> [RowMenuItem] {
        if let batch = batchItems(for: task, model) { return batch }
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
