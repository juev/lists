package org.evsyukov.lists.ui

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import uniffi.lists_core.Scope
import uniffi.lists_core.SortMode

/** R157: the id a moved row is put right after in [order], or null for the first place. */
internal fun placedAfter(order: List<String>, id: String): String? {
    val index = order.indexOf(id)
    return if (index > 0) order[index - 1] else null
}

/** R157: [this] with the element at [from] taken out and put in at [to]. */
internal fun <T> List<T>.moved(from: Int, to: Int): List<T> =
    if (from == to || from !in indices || to !in indices) this else toMutableList().apply { add(to, removeAt(from)) }

/**
 * R157: whether the rows of the view are put in order by hand: Inbox and a list sorted by hand (R2), as on macOS.
 * Not while a search is open or tasks are selected (R109).
 */
internal fun UiState.reorderable(): Boolean {
    if (selection != null || !search.isNullOrBlank()) return false
    val list = when (val s = scope) {
        Scope.Inbox -> list("inbox")
        is Scope.List -> list(s.id)
        else -> null
    }
    return list?.sort == SortMode.MANUAL
}

/** How a drag of a row ended (R157). */
sealed interface Dropped {
    /** The row went to another place: right after [after], or first. */
    data class Moved(val id: String, val after: String?) : Dropped

    /** The finger let go where it pressed: the long press opens what it opened before (the menu). */
    data object Still : Dropped

    /** The finger moved, but the row kept its place. */
    data object Kept : Dropped
}

/** R157: the row being dragged in a view, and the order of the rows while it is dragged. */
@Stable
class Reorder {
    /** The id of the dragged row; null when nothing is dragged. */
    var dragging by mutableStateOf<String?>(null)
        private set

    /** The order shown while dragging; null otherwise. */
    var order by mutableStateOf<List<String>?>(null)
        private set

    /** How far the dragged row is drawn from its place in the column, in pixels. */
    var offset by mutableFloatStateOf(0f)
        private set

    private var moved = false
    private var travel = 0f
    private var initial: List<String> = emptyList()

    fun start(id: String, ids: List<String>) {
        dragging = id
        order = ids
        initial = ids
        offset = 0f
        moved = false
        travel = 0f
    }

    /**
     * Follows the finger by [dy] pixels. The row trades places with the row under its middle, which a
     * lazy column with [rows] has laid out under the key [keyOf] of its id.
     */
    fun drag(dy: Float, rows: LazyListState, keyOf: (String) -> Any) {
        if (dragging == null) return
        offset += dy
        travel += kotlin.math.abs(dy)
        settle(rows, keyOf)
    }

    /**
     * Called on every frame while a row is dragged: held near an edge of the column, the rows scroll
     * under it, faster the closer it is, so a row is taken past what is on screen. The row is drawn
     * that much further, to stay under the finger.
     */
    fun autoscroll(rows: LazyListState, keyOf: (String) -> Any) {
        val id = dragging ?: return
        val info = rows.layoutInfo
        val self = info.visibleItemsInfo.firstOrNull { it.key == keyOf(id) } ?: return
        val step = edgeStep(self.offset + offset, self.size.toFloat(), info.viewportStartOffset.toFloat(), info.viewportEndOffset.toFloat())
        if (step == 0f) return
        offset += rows.dispatchRawDelta(step)
        settle(rows, keyOf)
    }

    /** Puts the dragged row in place of the row under its middle. */
    private fun settle(rows: LazyListState, keyOf: (String) -> Any) {
        val id = dragging ?: return
        val current = order ?: return
        val items = rows.layoutInfo.visibleItemsInfo
        val self = items.firstOrNull { it.key == keyOf(id) } ?: return
        val middle = self.offset + offset + self.size / 2f
        val target = items.firstOrNull { item ->
            item.key != self.key && middle >= item.offset && middle < item.offset + item.size &&
                current.any { keyOf(it) == item.key }
        } ?: return
        val to = current.indexOfFirst { keyOf(it) == target.key }
        val from = current.indexOf(id)
        order = current.moved(from, to)
        // The row has a new place: what it was drawn away from it shrinks by the distance it moved.
        offset -= (target.offset - self.offset)
        moved = true
    }

    /** Ends the drag; a finger that travelled less than [slop] pixels in all did not drag. */
    fun drop(slop: Float): Dropped {
        val id = dragging
        val now = order
        val result = when {
            // Taken away and brought back is no move.
            id != null && now != null && moved && now != initial -> Dropped.Moved(id, placedAfter(now, id))
            travel < slop -> Dropped.Still
            else -> Dropped.Kept
        }
        dragging = null
        offset = 0f
        moved = false
        travel = 0f
        // A moved row stays where it was put until the view is read again with it there (see [forget]).
        if (result !is Dropped.Moved) order = null
        return result
    }

    /** The view was read again: the order of the store is shown from here on. */
    fun forget() {
        if (dragging == null) order = null
    }

    fun cancel() {
        dragging = null
        order = null
        offset = 0f
        moved = false
        travel = 0f
    }
}

/**
 * R157: how far the rows scroll in a frame under a dragged row whose top is at [top] and which is [size] high,
 * in a column that shows from [start] to [end]: nothing outside the strip of one row at each edge, up to a
 * quarter of a row at the very edge; negative toward the start.
 */
internal fun edgeStep(top: Float, size: Float, start: Float, end: Float): Float {
    if (size <= 0f) return 0f
    val towardEnd = top + size - (end - size)
    val towardStart = (start + size) - top
    return when {
        towardEnd > 0f -> (towardEnd / size).coerceAtMost(1f) * size / 4f
        towardStart > 0f -> -(towardStart / size).coerceAtMost(1f) * size / 4f
        else -> 0f
    }
}

/**
 * R157: what the long press of a row does where rows are put in order by hand: it drags the row.
 * [onEnd] gets the touch slop and says how the drag ended; let go in place, the row opens what a long press opens.
 */
class RowDrag(
    val onStart: () -> Unit,
    val onDrag: (dy: Float) -> Unit,
    val onEnd: (slop: Float) -> Dropped,
    val onCancel: () -> Unit,
)

/** R157: the place a row of fixed height [row] lands on when dragged [offset] pixels from [from], among [count] rows. */
internal fun landing(from: Int, offset: Float, row: Float, count: Int): Int =
    if (row <= 0f || count <= 0) from else (from + kotlin.math.round(offset / row).toInt()).coerceIn(0, count - 1)

/** R157: how many rows [index] is drawn away from its place while the row at [from] is dragged to [to]. */
internal fun shiftOf(index: Int, from: Int, to: Int): Int = when {
    index == from -> 0
    from < to && index in (from + 1)..to -> -1
    to < from && index in to until from -> 1
    else -> 0
}
