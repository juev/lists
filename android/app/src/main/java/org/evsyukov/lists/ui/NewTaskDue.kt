package org.evsyukov.lists.ui

import uniffi.lists_core.Priority

/**
 * The due date a new task gets without the person picking one (R75): today in
 * a list whose default is "due today" (R2). The list gives its date only to a
 * task without a start date, as in the core. The view gives none.
 */
internal fun presetDue(listDueToday: Boolean, start: String?, today: String): String? =
    today.takeIf { listDueToday && start == null }

/**
 * The due date a task just created is to end up with (R41, R75).
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

/**
 * The priority a task just created is to end up with (R41, R75).
 *
 * `picked` is what the person chose next to the flag, null while the field is
 * untouched: the task then keeps `created`, the priority the core gave it
 * from its title or its list. A chosen priority wins over both. Choosing
 * "none" takes the default of the list away and leaves `typed`, the priority
 * the title names.
 */
internal fun finalPriority(picked: Priority?, created: Priority, typed: Priority): Priority = when (picked) {
    null -> created
    Priority.NONE -> typed
    else -> picked
}

/**
 * The due date the card shows as set (R64): the one picked in the card, else
 * the one the title names, else the one the list gives. It is the date
 * [finalDue] leaves the task with.
 */
internal fun shownDue(picked: String?, typed: String?, preset: String?): String? = picked ?: typed ?: preset

/**
 * The priority the card shows as set (R64), the one [finalPriority] leaves
 * the task with: a chosen one first; with the field untouched or set to
 * "none" the one the title names; the default of the list only while the
 * field is untouched.
 */
internal fun shownPriority(picked: Priority?, typed: Priority, preset: Priority?): Priority = when (picked) {
    null -> typed.takeIf { it != Priority.NONE } ?: preset ?: Priority.NONE
    Priority.NONE -> typed
    else -> picked
}
