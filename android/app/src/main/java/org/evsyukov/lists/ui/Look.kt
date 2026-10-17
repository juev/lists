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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.evsyukov.lists.title
import uniffi.lists_core.Priority

// The colours of the icons of the built-in views (R79): the same as on macOS, a lighter shade in the dark look.
// They come neither from a list nor from the dynamic palette.
internal enum class ViewTint(val light: Long, val dark: Long) {
    Blue(0xFF007AFF, 0xFF0A84FF),
    Yellow(0xFFFFCC00, 0xFFFFD60A),
    Pink(0xFFFF2D55, 0xFFFF375F),
    Teal(0xFF30B0C7, 0xFF40C8E0),
    Green(0xFF34C759, 0xFF30D158),
    Gray(0xFF8E8E93, 0xFF98989D),
}

@Composable
internal fun viewTint(tint: ViewTint): Color =
    Color(if (MaterialTheme.colorScheme.surface.luminance() < 0.5f) tint.dark else tint.light)

/** The colour of a priority, in a row and in a chip. */
val PriorityColor = Color(0xFFE8890C)

/** R72: the colour of the bar a row shows for the priority of its task; none for a task without one. */
fun priorityBarColor(priority: Priority): Color? = when (priority) {
    Priority.HIGH -> Color(0xFFE5484D)
    Priority.MEDIUM -> PriorityColor
    Priority.LOW -> Color(0xFF3B82F6)
    else -> null
}

/** R72: the bar after the mark of a row. Its place is kept for a task without a priority; [tall] is a row of two lines. */
@Composable
fun PriorityBar(priority: Priority, tall: Boolean) {
    val color = priorityBarColor(priority)
    val name = priority.title()
    Box(
        Modifier
            .padding(end = 10.dp)
            .width(3.dp)
            .height(if (tall) 34.dp else 20.dp)
            .background(color ?: Color.Transparent, RoundedCornerShape(2.dp))
            .then(if (color != null) Modifier.semantics { contentDescription = name } else Modifier)
    )
}

enum class MarkState { Open, Done, Wont, History }

/**
 * The completion mark (R95): small, thin and muted, without the colour of the
 * list. A subtask in the card of its task has a round one (R96).
 */
@Composable
fun Mark(state: MarkState, description: String?, modifier: Modifier = Modifier, round: Boolean = false) {
    val color = MaterialTheme.colorScheme.outline
    // R133: a record of a repeat whose completion can no longer be taken back shows the repeat icon instead.
    if (state == MarkState.History) {
        Icon(Icons.Outlined.Repeat, description, modifier.size(16.dp), tint = color)
        return
    }
    Box(
        modifier
            .size(16.dp)
            .border(1.5.dp, color, if (round) CircleShape else RoundedCornerShape(5.dp))
            .semantics { if (description != null) contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        when (state) {
            MarkState.Done -> Icon(Icons.Outlined.Check, null, Modifier.size(12.dp), tint = color)
            MarkState.Wont -> Icon(Icons.Outlined.Close, null, Modifier.size(12.dp), tint = color)
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
    color: Color = MaterialTheme.colorScheme.onSurface,
    trailing: ImageVector? = null,
    trailingLabel: String? = null,
    /** Null for a value that is only shown, as a tag read from the title. */
    onClick: (() -> Unit)?,
) {
    Row(
        Modifier
            .clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f))
            .clickable(enabled = onClick != null, role = Role.Button) { onClick?.invoke() }
            .heightIn(min = 32.dp)
            .padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        if (icon != null) Icon(icon, label, Modifier.size(16.dp), tint = color)
        Text(text, style = MaterialTheme.typography.labelLarge, color = color, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
        if (trailing != null) Icon(trailing, trailingLabel, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.outline)
    }
}

/** A field that is not set: a light icon without a caption at the right of the row of fields. */
@Composable
fun LightIcon(icon: ImageVector, label: String, onClick: () -> Unit) {
    Box(Modifier.size(40.dp).clip(CircleShape).clickable(role = Role.Button, onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, label, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.outline)
    }
}

/** The row of fields: chips for what is set at the left, icons for what is not at the right; chips that do not fit go to the next line. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun FieldsRow(modifier: Modifier = Modifier, chips: @Composable () -> Unit, icons: @Composable RowScope.() -> Unit) {
    FlowRow(modifier, horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        chips()
        Row(Modifier.weight(1f).heightIn(min = 32.dp), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically, content = icons)
    }
}
