package org.evsyukov.lists.ui

/**
 * The due date a new task gets without the person picking one (R57): the date
 * of the view, or today in a list whose default is "due today" (R2). The list
 * gives its date only to a task without a start date, as in the core.
 */
internal fun presetDue(viewDue: String?, listDueToday: Boolean, start: String?, today: String): String? =
    viewDue ?: today.takeIf { listDueToday && start == null }

/**
 * The due date a task just created is to end up with (R41, R57).
 *
 * `due` is what stood next to the due icon. A date picked there wins over
 * everything; one that was only preset yields to `created`, the date the core
 * gave the task from its title or its list. With `removed` the person took
 * the preset away: the task keeps only `typed`, the date its title names.
 */
internal fun finalDue(due: String?, isPreset: Boolean, removed: Boolean, created: String?, typed: String?): String? = when {
    due != null && !isPreset -> due
    due != null -> created ?: due
    removed -> typed
    else -> created
}
