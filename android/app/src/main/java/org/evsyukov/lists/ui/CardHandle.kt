package org.evsyukov.lists.ui

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import org.evsyukov.lists.R
import org.evsyukov.lists.str
import kotlin.math.abs

/** What a drag of the handle asks of its card (R97, R99). */
internal enum class HandleDrag { Expand, Collapse, Close }

/**
 * What a drag that has gone [dy] from where it started asks of a card that
 * was [expanded] then; nothing until it has left the touch [slop]. Up
 * expands, down collapses an expanded card and closes one that is not.
 */
internal fun handleDrag(dy: Float, slop: Float, expanded: Boolean): HandleDrag? = when {
    abs(dy) <= slop -> null
    dy < 0 -> HandleDrag.Expand
    expanded -> HandleDrag.Collapse
    else -> HandleDrag.Close
}

/**
 * The handle of a card (R97, R99): a drag up expands the card, a drag down
 * collapses an expanded one. A drag down on a card that is not expanded goes
 * to [onClose]; without it the drag is left to the sheet, which closes. There
 * is no button for the size, so a screen reader gets it as the action of the
 * handle.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CardHandle(
    expanded: Boolean,
    onExpanded: (Boolean) -> Unit,
    /** Where the bar itself stands: an expanded sheet keeps it below the status bar, where a drag belongs to the system. */
    barModifier: Modifier = Modifier,
    onClose: (() -> Unit)? = null,
) {
    val isExpanded by rememberUpdatedState(expanded)
    val setExpanded by rememberUpdatedState(onExpanded)
    val close by rememberUpdatedState(onClose)
    val action = str(if (expanded) R.string.collapse_card else R.string.expand_card)
    Box(
        Modifier.fillMaxWidth()
            .semantics { onClick(action) { setExpanded(!isExpanded); true } }
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val wasExpanded = isExpanded
                    var dy = 0f
                    var decided = false
                    while (true) {
                        val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                        if (!change.pressed) break
                        dy += change.positionChange().y
                        val asked = if (decided) null else handleDrag(dy, viewConfiguration.touchSlop, wasExpanded)
                        if (asked != null) {
                            decided = true
                            when (asked) {
                                HandleDrag.Expand -> setExpanded(true)
                                HandleDrag.Collapse -> setExpanded(false)
                                HandleDrag.Close -> close?.invoke()
                            }
                        }
                        // Kept from the sheet, or it would follow the finger and close a card that only changes its size.
                        if (dy < 0 || wasExpanded || close != null) change.consume()
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        BottomSheetDefaults.DragHandle(barModifier)
    }
}
