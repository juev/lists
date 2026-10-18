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
import uniffi.lists_core.Counts
import uniffi.lists_core.DueWindow
import uniffi.lists_core.FilterSpec
import uniffi.lists_core.FilterStatus
import uniffi.lists_core.Freq
import uniffi.lists_core.Priority
import uniffi.lists_core.Repeat
import uniffi.lists_core.SavedFilter
import uniffi.lists_core.Scope
import uniffi.lists_core.SortMode
import uniffi.lists_core.TagCount
import uniffi.lists_core.TaskItem
import uniffi.lists_core.TaskList
import java.time.LocalDate

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

/** The lists of the demo data (`cargo run --example demo`), with their colours. */
internal fun catalogLists(): List<TaskList> = listOf(
    TaskList("inbox", "Inbox", "", "", SortMode.MANUAL, false, Priority.NONE, false, false, 2u),
    TaskList("work", "Работа", "#2f7bf6", "", SortMode.MANUAL, false, Priority.NONE, false, false, 4u),
    TaskList("home", "Дом", "#34c759", "", SortMode.MANUAL, false, Priority.NONE, false, false, 3u),
    TaskList("trip", "Поездка в Казань", "#ff9500", "", SortMode.MANUAL, false, Priority.NONE, false, false, 2u),
)

/**
 * Rows of the demo data in every state a row takes. The dates count from [today] and have no time,
 * so a picture says "Yesterday", "Today" and "Tomorrow" whatever the day and the hour it is drawn.
 */
internal fun catalogTasks(today: LocalDate): List<TaskItem> {
    fun task(
        id: String,
        title: String,
        list: String = "work",
        due: LocalDate? = null,
        priority: Priority = Priority.NONE,
        done: Boolean = false,
        wont: Boolean = false,
        project: Boolean = false,
        repeat: Repeat? = null,
        notes: String = "",
        files: UInt = 0u,
        subtasks: UInt = 0u,
    ) = TaskItem(
        id, list, null, null, title, notes, null, due?.toString(), priority, emptyList(), repeat, null,
        if (done || wont) "${today}T09:00" else null, wont, false, false, project, subtasks, 0u, files, due?.toString(), null,
    )
    val weekly = Repeat(Freq.WEEKLY, 1u, emptyList(), null, null, null, false, null, null)
    return listOf(
        task("overdue", "Ответить на письмо подрядчика", due = today.minusDays(1), priority = Priority.MEDIUM),
        task("water", "Полить цветы", list = "home", due = today, repeat = weekly),
        task("report", "Квартальный отчёт", due = today.plusDays(1), priority = Priority.HIGH, notes = "Цифры", files = 1u, subtasks = 3u),
        task("long", "Обновить презентацию для выставки и разослать её всем участникам заранее", due = today, priority = Priority.LOW),
        task("site", "Запуск сайта", list = "inbox", project = true),
        task("invoice", "Отправить счёт заказчику", done = true),
        task("dentist", "Записаться к стоматологу", list = "inbox", wont = true),
    )
}

/** The rows of [catalogTasks] as a view shows them: with the list under the title where lists mix (R72). */
@Composable
internal fun TaskRowsCatalog(today: LocalDate, scope: Scope) {
    val state = UiState(lists = catalogLists(), scope = scope)
    Column {
        for (task in catalogTasks(today)) {
            TaskRow(task, state, onToggle = {}, onOpen = {}, menu = {}, showOrigin = scope == Scope.Today)
        }
    }
}

/** The panel of lists with the demo lists, a project, a filter and a tag; the list Работа is open. */
@Composable
internal fun DrawerCatalog(today: LocalDate) {
    val project = catalogTasks(today).first { it.isProject }.copy(subtasksTotal = 2u)
    val filter = SavedFilter("week", "Ближайшие 7 дней", FilterSpec(DueWindow.Any, emptyList(), emptyList(), Priority.NONE, FilterStatus.OPEN, ""), 10u)
    val state = UiState(
        lists = catalogLists(),
        projects = listOf(project),
        filters = listOf(filter),
        tags = listOf(TagCount("отчёты", 1u)),
        counts = Counts(2u, 3u, 1u, 7u, 0u, 0u, 0u, 0u),
        scope = Scope.List("work"),
    )
    Drawer(state, {}, {}, { _, _ -> }, {}, {}, {}, {}, {}, {}, {})
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

@Preview(name = "Rows of Today", heightDp = 640)
@Composable
private fun RowsToday() = CatalogPage(dark = false, title = "Today") { TaskRowsCatalog(LocalDate.now(), Scope.Today) }

@Preview(name = "Panel of lists", heightDp = 900)
@Composable
private fun DrawerPreview() = ListsTheme(dark = false, dynamic = false) { DrawerCatalog(LocalDate.now()) }
