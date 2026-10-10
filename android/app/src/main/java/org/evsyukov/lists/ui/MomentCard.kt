package org.evsyukov.lists.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material3.AssistChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimeInput
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import org.evsyukov.lists.R
import org.evsyukov.lists.hasTime
import org.evsyukov.lists.momentString
import org.evsyukov.lists.parseMoment
import org.evsyukov.lists.str
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.LocalTime
import java.time.YearMonth
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.format.TextStyle
import java.time.temporal.WeekFields
import java.util.Locale

/** The day and the time the date card opens with (R110): those of the task, or today; a reminder always has a time. */
internal fun initialMoment(value: String?, timeRequired: Boolean, today: LocalDate): Pair<LocalDate, LocalTime?> {
    val current = value?.let(::parseMoment)
    val time = current?.takeIf { hasTime(value) }?.toLocalTime() ?: if (timeRequired) LocalTime.of(9, 0) else null
    return (current?.toLocalDate() ?: today) to time
}

/** The weeks of a month as rows of seven cells from the first day of the week; a cell outside the month is empty (R110). */
internal fun monthGrid(month: YearMonth, firstDay: DayOfWeek): List<List<LocalDate?>> {
    val lead = (month.atDay(1).dayOfWeek.value - firstDay.value + 7) % 7
    val cells = List<LocalDate?>(lead) { null } + (1..month.lengthOfMonth()).map(month::atDay)
    return cells.chunked(7).map { week -> week + List<LocalDate?>(7 - week.size) { null } }
}

/** The days of the week in the order of the grid. */
internal fun weekdaysFrom(firstDay: DayOfWeek): List<DayOfWeek> = (0L..6L).map(firstDay::plus)

/**
 * R110: a date with an optional time, chosen in one card. The quick choices
 * are one tap; the month and the time are in the same card.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun MomentDialog(title: String, value: String?, timeRequired: Boolean = false, onPick: (String?) -> Unit, onDismiss: () -> Unit) {
    val today = LocalDate.now()
    val (firstDay, firstTime) = initialMoment(value, timeRequired, today)
    var day by rememberSaveable { mutableStateOf(firstDay) }
    // Kept as text: a saved state holds a string.
    var shown by rememberSaveable { mutableStateOf(YearMonth.from(firstDay).toString()) }
    var timed by rememberSaveable { mutableStateOf(firstTime != null) }
    var timeOpen by rememberSaveable { mutableStateOf(timeRequired) }
    val time = rememberTimePickerState(firstTime?.hour ?: 9, firstTime?.minute ?: 0, is24Hour = true)

    fun finish(picked: LocalDate) {
        onPick(momentString(picked, if (timed) time.hour else null, if (timed) time.minute else null))
        onDismiss()
    }
    /** A reminder still needs its time looked at: the quick choice only moves the day. */
    fun quick(picked: LocalDate) {
        if (!timeRequired) return finish(picked)
        day = picked
        shown = YearMonth.from(picked).toString()
    }

    FormDialog(
        title = title,
        onDismiss = onDismiss,
        confirmButton = { TextButton(onClick = { finish(day) }) { Text(str(R.string.done)) } },
        dismissButton = {
            Row {
                if (value != null) {
                    TextButton(onClick = { onPick(null); onDismiss() }) { Text(str(R.string.remove), color = MaterialTheme.colorScheme.error) }
                }
                TextButton(onClick = onDismiss) { Text(str(R.string.cancel)) }
            }
        },
    ) {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                AssistChip(onClick = { quick(today) }, label = { Text(str(R.string.today)) })
                AssistChip(onClick = { quick(today.plusDays(1)) }, label = { Text(str(R.string.tomorrow)) })
                AssistChip(onClick = { quick(today.plusDays(7)) }, label = { Text(str(R.string.in_a_week)) })
            }
            MonthGrid(YearMonth.parse(shown), day, today, onMonth = { shown = it.toString() }, onDay = { day = it })
            Row(
                Modifier.fillMaxWidth()
                    .clickable(role = Role.Button) {
                        // Opening the fields gives the day a time; "Remove time" takes it back.
                        timed = true
                        timeOpen = true
                    }
                    .heightIn(min = 48.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(str(R.string.time))
                // With the fields open the time is read in them; its place is taken by the way back.
                if (timeOpen && !timeRequired) {
                    TextButton(onClick = { timed = false; timeOpen = false }) { Text(str(R.string.remove_time)) }
                } else {
                    Text(
                        if (timed) "%02d:%02d".format(time.hour, time.minute) else str(R.string.time_off),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            if (timeOpen) TimeInput(time, Modifier.align(Alignment.CenterHorizontally))
        }
    }
}

/** The month of the card: its name between the arrows, the days of the week and the days. */
@Composable
private fun MonthGrid(month: YearMonth, selected: LocalDate, today: LocalDate, onMonth: (YearMonth) -> Unit, onDay: (LocalDate) -> Unit) {
    val locale: Locale = LocalConfiguration.current.locales[0]
    val firstDay = WeekFields.of(locale).firstDayOfWeek
    val spoken = DateTimeFormatter.ofLocalizedDate(FormatStyle.FULL).withLocale(locale)
    Column(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { onMonth(month.minusMonths(1)) }) {
                Icon(Icons.AutoMirrored.Outlined.KeyboardArrowLeft, str(R.string.previous_month))
            }
            Text(
                // The name of a month alone is in lower case in some languages.
                month.format(DateTimeFormatter.ofPattern("LLLL yyyy", locale)).replaceFirstChar { it.titlecase(locale) },
                Modifier.weight(1f),
                style = MaterialTheme.typography.titleSmall,
                textAlign = TextAlign.Center,
            )
            IconButton(onClick = { onMonth(month.plusMonths(1)) }) {
                Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, str(R.string.next_month))
            }
        }
        Row(Modifier.fillMaxWidth()) {
            for (weekday in weekdaysFrom(firstDay)) {
                Text(
                    weekday.getDisplayName(TextStyle.SHORT_STANDALONE, locale),
                    Modifier.weight(1f),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    maxLines = 1,
                )
            }
        }
        for (week in monthGrid(month, firstDay)) {
            Row(Modifier.fillMaxWidth()) {
                for (date in week) {
                    Box(Modifier.weight(1f).sizeIn(maxHeight = 44.dp).aspectRatio(1f).padding(2.dp), contentAlignment = Alignment.Center) {
                        if (date != null) DayCell(date, date == selected, date == today, spoken.format(date)) { onDay(date) }
                    }
                }
            }
        }
    }
}

@Composable
private fun DayCell(date: LocalDate, selected: Boolean, today: Boolean, spoken: String, onClick: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    Box(
        Modifier
            .aspectRatio(1f)
            .clip(CircleShape)
            .then(
                when {
                    selected -> Modifier.background(colors.primary)
                    today -> Modifier.border(BorderStroke(1.dp, colors.primary), CircleShape)
                    else -> Modifier
                }
            )
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = spoken; this.selected = selected },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            date.dayOfMonth.toString(),
            style = MaterialTheme.typography.bodyMedium,
            color = when {
                selected -> colors.onPrimary
                today -> colors.primary
                else -> colors.onSurface
            },
        )
    }
}
