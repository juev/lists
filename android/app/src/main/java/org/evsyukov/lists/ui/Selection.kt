package org.evsyukov.lists.ui

import org.evsyukov.lists.R
import uniffi.lists_core.Priority
import uniffi.lists_core.Store
import uniffi.lists_core.TaskItem

/** R109: one action on all the selected tasks. */
sealed interface BatchAction {
    data object Complete : BatchAction
    data object WontDo : BatchAction
    data object Delete : BatchAction
    /** Out of the trash; the only action for a task that is there. */
    data object Restore : BatchAction
    data class Due(val value: String) : BatchAction
    data class Start(val value: String) : BatchAction
    data class SetPriority(val value: Priority) : BatchAction
    data class MoveTo(val listId: String) : BatchAction
    /** R129: into a project, at its end. */
    data class MoveToProject(val projectId: String) : BatchAction
    data class Tag(val name: String) : BatchAction
}

/** What the bar of the selection offers (R109): the usual actions, or the one action there is for the selected rows. */
enum class SelectionActions { Usual, Restore, DeleteRecords }

/** Only tasks in the trash can be restored and nothing else; only records of completed occurrences can be deleted and nothing else. */
fun selectionActions(selected: List<TaskItem>): SelectionActions = when {
    selected.isEmpty() -> SelectionActions.Usual
    selected.all { it.deleted } -> SelectionActions.Restore
    selected.all { it.isLog } -> SelectionActions.DeleteRecords
    else -> SelectionActions.Usual
}

/** A tag as the core stores it. */
internal fun cleanTag(tag: String): String = tag.trim().trimStart('#').lowercase()

/**
 * R129: whether the task can be moved into the project. A project and a task with lines under it stay at the top level
 * (R10), and a task already in the project stays where it is, as with a drop onto a project (R123).
 */
fun TaskItem.goesInto(projectId: String): Boolean = !(isProject || subtasksTotal > 0u || id == projectId || parentId == projectId)

/** Whether the action applies to this task; one it does not apply to is passed over. */
fun BatchAction.appliesTo(task: TaskItem): Boolean {
    // A task in the trash is only restored, and a record of a completed occurrence only deleted.
    if (task.deleted) return this == BatchAction.Restore
    if (task.isLog) return this == BatchAction.Delete
    return when (this) {
        BatchAction.Restore -> false
        BatchAction.Complete, BatchAction.WontDo -> task.done == null
        BatchAction.Delete -> true
        is BatchAction.Due -> task.due != value
        is BatchAction.Start -> task.start != value
        is BatchAction.SetPriority -> task.priority != value
        is BatchAction.MoveTo -> !(task.parentId == null && task.listId == listId)
        is BatchAction.MoveToProject -> task.goesInto(projectId)
        is BatchAction.Tag -> cleanTag(name).let { tag -> tag.isNotEmpty() && tag !in task.tags }
    }
}

fun BatchAction.run(store: Store, id: String) {
    when (this) {
        BatchAction.Complete -> store.completeTask(id)
        BatchAction.WontDo -> store.wontDoTask(id)
        BatchAction.Delete -> store.deleteTask(id)
        BatchAction.Restore -> store.restoreTask(id)
        is BatchAction.Due -> store.setDue(id, value)
        is BatchAction.Start -> store.setStart(id, value)
        is BatchAction.SetPriority -> store.setPriority(id, value)
        is BatchAction.MoveTo -> store.moveToList(id, listId)
        is BatchAction.MoveToProject -> store.moveToProject(id, projectId)
        is BatchAction.Tag -> store.addTag(id, name)
    }
}

/** The text of the bar after the action; it takes the number of tasks that were changed. */
fun BatchAction.done(): Int = when (this) {
    BatchAction.Complete, BatchAction.WontDo -> R.string.batch_completed
    BatchAction.Delete -> R.string.batch_deleted
    BatchAction.Restore -> R.string.batch_restored
    is BatchAction.MoveTo, is BatchAction.MoveToProject -> R.string.batch_moved
    else -> R.string.batch_changed
}

/** The selection after the view was read again: a task that is no longer shown drops out of it. */
fun Set<String>.kept(shown: Collection<String>): Set<String> = intersect(shown.toSet())

/**
 * The selection while a finger is dragged over the circles: what was selected
 * before the drag, and the rows from the one it started on to the one under the
 * finger. Going back gives up the rows the drag added.
 */
fun dragged(base: Set<String>, order: List<String>, from: String, to: String): Set<String> {
    val a = order.indexOf(from)
    val b = order.indexOf(to)
    if (a < 0 || b < 0) return base
    return base + order.subList(minOf(a, b), maxOf(a, b) + 1)
}
