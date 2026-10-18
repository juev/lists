package org.evsyukov.lists.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import uniffi.lists_core.Priority

/*
 * The colours that mean something of their own (#369). Everything else comes from the colour scheme of
 * the theme: the dynamic palette on Android 12 and later, the Material baseline before (ListsTheme).
 * A meaning is not handed to a colour of the scheme by chance: a late date is `error` of the scheme,
 * a priority and a built-in view have fixed colours that read the same in any palette.
 */

/** The colours of the icons of the built-in views (R79): the same as on macOS, a lighter shade in the dark look. */
enum class ViewTint(val light: Long, val dark: Long) {
    Blue(0xFF007AFF, 0xFF0A84FF),
    Yellow(0xFFFFCC00, 0xFFFFD60A),
    Pink(0xFFFF2D55, 0xFFFF375F),
    Teal(0xFF30B0C7, 0xFF40C8E0),
    Green(0xFF34C759, 0xFF30D158),
    Gray(0xFF8E8E93, 0xFF98989D),
}

/** The shade of [tint] for the look on screen: dark when the surface is dark. */
@Composable
fun viewTint(tint: ViewTint): Color =
    Color(if (isDarkLook()) tint.dark else tint.light)

/** True when the look on screen is dark. */
@Composable
fun isDarkLook(): Boolean = MaterialTheme.colorScheme.surface.luminance() < 0.5f

/** R159: the ground of a screen of rows, a tone apart from the containers that stand on it. */
@Composable
fun screenGround(): Color = if (isDarkLook()) MaterialTheme.colorScheme.surfaceContainerLowest else MaterialTheme.colorScheme.surfaceContainer

/** R159: the container of the rows of a group and of the sections of the settings. */
@Composable
fun groupContainer(): Color = if (isDarkLook()) MaterialTheme.colorScheme.surfaceContainer else MaterialTheme.colorScheme.surfaceContainerLowest

/** The colours of the priorities (R72): of the bar of a row and of the chip in a card. */
object PriorityColors {
    val high = Color(0xFFE5484D)
    val medium = Color(0xFFE8890C)
    val low = Color(0xFF3B82F6)

    /** The chip of the priority in a card: one colour whatever the level, the level is its text. */
    val chip = medium

    /** The colour of [priority]; none for a task without one. */
    fun of(priority: Priority): Color? = when (priority) {
        Priority.HIGH -> high
        Priority.MEDIUM -> medium
        Priority.LOW -> low
        else -> null
    }
}
