package org.evsyukov.lists.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.Flag
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.Repeat
import androidx.compose.material.icons.outlined.Sell
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import org.evsyukov.lists.ui.theme.ListsTheme
import org.evsyukov.lists.ui.theme.PriorityColors
import org.evsyukov.lists.ui.theme.Space
import org.evsyukov.lists.ui.theme.ViewTint
import org.evsyukov.lists.ui.theme.groupHeading
import org.evsyukov.lists.ui.theme.viewTint
import uniffi.lists_core.Priority

/*
 * The building blocks of the screens, each in the states it takes (#369). The previews show them in
 * the IDE; the screenshot tests in src/test draw the same functions in the light and the dark look and
 * compare them with the pictures kept in src/test/screenshots.
 */

/** A catalog page: the theme with the fixed palette, a surface and a heading. */
@Composable
internal fun CatalogPage(dark: Boolean, title: String, content: @Composable () -> Unit) {
    ListsTheme(dark = dark, dynamic = false) {
        Surface {
            Column(Modifier.padding(Space.xl), verticalArrangement = Arrangement.spacedBy(Space.m)) {
                Text(title, style = MaterialTheme.typography.groupHeading)
                content()
            }
        }
    }
}

/** The completion marks (R95, R96, R133) and the bars of the priorities (R72). */
@Composable
internal fun MarksCatalog() {
    Row(horizontalArrangement = Arrangement.spacedBy(Space.xl), verticalAlignment = Alignment.CenterVertically) {
        for (state in MarkState.entries) Mark(state, state.name)
        Mark(MarkState.Open, "round", round = true)
        Mark(MarkState.Done, "round done", round = true)
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        for (priority in listOf(Priority.HIGH, Priority.MEDIUM, Priority.LOW, Priority.NONE)) {
            PriorityBar(priority, tall = false)
            PriorityBar(priority, tall = true)
        }
    }
}

/** The row of fields (R64): chips of the fields that are set, light icons of those that are not. */
@Composable
internal fun FieldsCatalog() {
    FieldsRow(
        chips = {
            ValueChip("Tomorrow", Icons.Outlined.CalendarMonth, "Due", onClick = {})
            ValueChip("High", Icons.Outlined.Flag, "Priority", color = PriorityColors.chip, onClick = {})
            ValueChip("#garden", null, onClick = null)
            ValueChip("A very long value that does not fit the row of fields", Icons.Outlined.Repeat, "Repeat", onClick = {})
        },
        icons = {
            LightIcon(Icons.Outlined.Notifications, "Reminder") {}
            LightIcon(Icons.Outlined.Sell, "Tag") {}
        },
    )
}

/** The colours of the built-in views (R79), as the panel and the titles show them. */
@Composable
internal fun ViewTintsCatalog() {
    Row(horizontalArrangement = Arrangement.spacedBy(Space.m)) {
        for (tint in ViewTint.entries) Pill(tint.name, viewTint(tint))
    }
}

@Preview(name = "Marks, light")
@Composable
private fun MarksLight() = CatalogPage(dark = false, title = "Marks") { MarksCatalog() }

@Preview(name = "Marks, dark")
@Composable
private fun MarksDark() = CatalogPage(dark = true, title = "Marks") { MarksCatalog() }

@Preview(name = "Fields", widthDp = 360)
@Composable
private fun FieldsLight() = CatalogPage(dark = false, title = "Fields") { FieldsCatalog() }

@Preview(name = "View tints, dark")
@Composable
private fun ViewTintsDark() = CatalogPage(dark = true, title = "View tints") { ViewTintsCatalog() }
