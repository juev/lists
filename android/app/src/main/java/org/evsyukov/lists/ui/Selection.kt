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

/** How the change an action made to one task is taken back. */
sealed interface Back {
    data object Reopen : Back
    data object Restore : Back
    /** Into the trash again, after a restoring that is taken back. */
    data object Trash : Back
    data class Due(val value: String?) : Back
    data class Start(val value: String?) : Back
    data class SetPriority(val value: Priority) : Back
    data class Place(val listId: String, val parentId: String?) : Back
    data class Untag(val name: String) : Back
}

/** What an action does to one task; [back] is null when the change cannot be taken back. */
data class Step(val back: Back?)

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

/** The step of the action for this task, or null when the action does not apply to it and the task is passed over. */
fun BatchAction.on(task: TaskItem): Step? {
    // A task in the trash is only restored, and a record of a completed occurrence only deleted.
    if (task.deleted) return if (this == BatchAction.Restore) Step(Back.Trash) else null
    if (task.isLog) return if (this == BatchAction.Delete) Step(Back.Restore) else null
    return when (this) {
        BatchAction.Restore -> null
        BatchAction.Complete, BatchAction.WontDo -> when {
            task.done != null -> null
            // A repeating task that moved on gets its dates back the same way (R128).
            else -> Step(Back.Reopen)
        }
        BatchAction.Delete -> Step(Back.Restore)
        is BatchAction.Due -> if (task.due == value) null else Step(Back.Due(task.due))
        is BatchAction.Start -> if (task.start == value) null else Step(Back.Start(task.start))
        is BatchAction.SetPriority -> if (task.priority == value) null else Step(Back.SetPriority(task.priority))
        is BatchAction.MoveTo -> if (task.parentId == null && task.listId == listId) null else Step(Back.Place(task.listId, task.parentId))
        is BatchAction.MoveToProject -> if (task.goesInto(projectId)) Step(Back.Place(task.listId, task.parentId)) else null
        is BatchAction.Tag -> cleanTag(name).let { tag -> if (tag.isEmpty() || tag in task.tags) null else Step(Back.Untag(tag)) }
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

fun Back.run(store: Store, id: String) {
    when (this) {
        // With the subtasks the action closed along with the task.
        Back.Reopen -> store.undoCloseTask(id)
        Back.Restore -> store.restoreTask(id)
        Back.Trash -> store.deleteTask(id)
        is Back.Due -> store.setDue(id, value)
        is Back.Start -> store.setStart(id, value)
        is Back.SetPriority -> store.setPriority(id, value)
        // The former place among its neighbours is not kept: the task comes first.
        is Back.Place -> store.moveTask(id, listId, parentId, null)
        is Back.Untag -> store.removeTag(id, name)
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
