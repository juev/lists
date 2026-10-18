package org.evsyukov.lists.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Repeat
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import org.evsyukov.lists.title
import org.evsyukov.lists.ui.theme.Corners
import org.evsyukov.lists.ui.theme.PriorityColors
import org.evsyukov.lists.ui.theme.Sizes
import org.evsyukov.lists.ui.theme.Space
import org.evsyukov.lists.ui.theme.label
import uniffi.lists_core.Priority

/** R72: the colour of the bar a row shows for the priority of its task; none for a task without one. */
fun priorityBarColor(priority: Priority): Color? = PriorityColors.of(priority)

/** R72: the bar after the mark of a row. Its place is kept for a task without a priority; R159 sets its size. */
@Composable
fun PriorityBar(priority: Priority) {
    val color = priorityBarColor(priority)
    val name = priority.title()
    Box(
        Modifier
            .padding(end = Space.l)
            .width(Sizes.priorityBar)
            .height(Sizes.priorityBarHeight)
            .background(color ?: Color.Transparent, Corners.bar)
            .then(if (color != null) Modifier.semantics { contentDescription = name } else Modifier)
    )
}

enum class MarkState { Open, Done, Wont, History }

/**
 * The completion mark (R159): a circle with a thin muted ring, without the colour of the list. Done, it is
 * filled with the primary colour and shows a tick; won't do, it is filled with the muted colour and shows a
 * cross. A subtask in the card of its task has the [small] one (R96).
 */
@Composable
fun Mark(state: MarkState, description: String?, modifier: Modifier = Modifier, small: Boolean = false) {
    val muted = MaterialTheme.colorScheme.outline
    val size = if (small) Sizes.roundMarkSmall else Sizes.roundMark
    // R133: a record of a repeat whose completion can no longer be taken back shows the repeat icon instead.
    if (state == MarkState.History) {
        Icon(Icons.Outlined.Repeat, description, modifier.size(size), tint = muted)
        return
    }
    val fill = when (state) {
        MarkState.Done -> MaterialTheme.colorScheme.primary
        MarkState.Wont -> muted
        else -> null
    }
    Box(
        modifier
            .size(size)
            .then(if (fill != null) Modifier.background(fill, Corners.round) else Modifier.border(Sizes.stroke, muted, Corners.round))
            .semantics { if (description != null) contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        val glyph = MaterialTheme.colorScheme.surface
        when (state) {
            MarkState.Done -> Icon(Icons.Outlined.Check, null, Modifier.size(Sizes.markGlyph), tint = glyph)
            MarkState.Wont -> Icon(Icons.Outlined.Close, null, Modifier.size(Sizes.markGlyph), tint = glyph)
            MarkState.Open, MarkState.History -> {}
        }
    }
}

/** A field that is set: its icon and its value at the left of the row of fields (R64, R96). */
@Composable
fun ValueChip(
    text: String,
    icon: ImageVector? = null,
    /** What the field is, for a screen reader: the icon alone says it to the eye. */
    label: String? = null,
    color: Color? = null,
    /** R159: the chip of the due date is tonal. */
    tonal: Boolean = false,
    trailing: ImageVector? = null,
    trailingLabel: String? = null,
    /** Null for a value that is only shown, as a tag read from the title. */
    onClick: (() -> Unit)?,
) {
    val ink = color ?: if (tonal) MaterialTheme.colorScheme.onSecondaryContainer else MaterialTheme.colorScheme.onSurface
    Row(
        Modifier
            .clip(Corners.chip)
            .background(if (tonal) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceContainerHigh)
            .clickable(enabled = onClick != null, role = Role.Button) { onClick?.invoke() }
            .heightIn(min = Sizes.chip)
            .padding(horizontal = Space.chipInset),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.chipGap),
    ) {
        if (icon != null) Icon(icon, label, Modifier.size(Sizes.mark), tint = ink)
        Text(text, style = MaterialTheme.typography.label, color = ink, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
        if (trailing != null) Icon(trailing, trailingLabel, Modifier.size(Sizes.metaIcon), tint = MaterialTheme.colorScheme.outline)
    }
}

/** A field that is not set: a light icon without a caption at the right of the row of fields. */
@Composable
fun LightIcon(icon: ImageVector, label: String, onClick: () -> Unit) {
    Box(Modifier.size(Sizes.lightTarget).clip(Corners.round).clickable(role = Role.Button, onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, label, Modifier.size(Sizes.lightIcon), tint = MaterialTheme.colorScheme.outline)
    }
}

/** The row of fields: chips for what is set at the left, icons for what is not at the right; chips that do not fit go to the next line. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun FieldsRow(modifier: Modifier = Modifier, chips: @Composable () -> Unit, icons: @Composable RowScope.() -> Unit) {
    FlowRow(modifier, horizontalArrangement = Arrangement.spacedBy(Space.m), verticalArrangement = Arrangement.spacedBy(Space.s)) {
        chips()
        Row(Modifier.weight(1f).heightIn(min = Sizes.chip), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically, content = icons)
    }
}
