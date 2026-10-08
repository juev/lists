package org.evsyukov.lists

import uniffi.lists_core.Freq
import uniffi.lists_core.Priority
import uniffi.lists_core.Repeat
import uniffi.lists_core.TaskList
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

// Dates travel through the core as "yyyy-MM-dd" or "yyyy-MM-ddTHH:mm" without a
// time zone: "tomorrow at nine" stays nine wherever the device is.

/** Looks a string up in the app's language. */
fun str(id: Int, vararg args: Any?): String = ListsApp.instance.getString(id, *args)

/** "1st" … "5th", used for "the n-th weekday of the month". */
fun ordinal(n: Int): String =
    str(listOf(R.string.ordinal_1, R.string.ordinal_2, R.string.ordinal_3, R.string.ordinal_4, R.string.ordinal_5)[n.coerceIn(1, 5) - 1])

// Formatters follow the current locale, so they are built on use, not cached.
private fun shortDay() = DateTimeFormatter.ofPattern("EEE, d MMM", Locale.getDefault())
private fun longDay() = DateTimeFormatter.ofPattern("EEEE, d MMMM", Locale.getDefault())
private fun withYear() = DateTimeFormatter.ofPattern("d MMM yyyy", Locale.getDefault())
private val moment = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm")

fun today(): String = LocalDate.now().toString()

fun plusDays(days: Long): String = LocalDate.now().plusDays(days).toString()

fun hasTime(value: String) = value.length > 10

/** Whether a task belongs to the Overdue group of Today (R84): its due day has passed. A start date does not count. */
fun dueDayPassed(due: String?, today: String = today()): Boolean = due != null && dayOf(due) < today

fun dayOf(value: String): String = value.take(10)

fun momentString(date: LocalDate, hour: Int?, minute: Int?): String =
    if (hour == null || minute == null) date.toString() else date.atTime(hour, minute).format(moment)

/** "18:30" for a moment with a time, nothing for a bare day. */
fun timeOf(value: String?): String? = value?.takeIf(::hasTime)?.takeLast(5)

// The calendar of a date picker counts days in UTC, whatever the zone of the device.
fun pickerMillis(day: LocalDate): Long = day.atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli()

fun pickerDay(millis: Long): LocalDate = Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate()

fun isOverdue(value: String): Boolean {
    if (!hasTime(value)) return dayOf(value) < today()
    val at = parseMoment(value) ?: return false
    return at < LocalDateTime.now()
}

/** "Сегодня", "Завтра, 18:30", "пт, 9 окт". */
fun dateLabel(value: String): String {
    val date = runCatching { LocalDate.parse(dayOf(value)) }.getOrNull() ?: return value
    val now = LocalDate.now()
    val text = when (ChronoUnit.DAYS.between(now, date)) {
        0L -> str(R.string.today)
        1L -> str(R.string.tomorrow)
        -1L -> str(R.string.yesterday)
        else -> date.format(if (date.year == now.year) shortDay() else withYear())
    }
    return if (hasTime(value)) "$text, ${value.takeLast(5)}" else text
}

/**
 * The due date as the row of a task shows it (R72), and whether it is late: an overdue date always with
 * its day; otherwise without the day when the heading of the group names it, which leaves the time or nothing.
 */
fun rowDate(due: String?, open: Boolean, dayInHeading: Boolean, label: (String) -> String = ::dateLabel): Pair<String, Boolean>? {
    if (due == null) return null
    val late = open && isOverdue(due)
    if (late && dayOf(due) < today()) return label(due) to true
    if (!dayInHeading) return label(due) to late
    return if (hasTime(due)) due.takeLast(5) to late else null
}

/** Section title for a day in the Upcoming view. */
fun dayHeading(day: String): String {
    val date = runCatching { LocalDate.parse(day) }.getOrNull() ?: return day
    val text = date.format(longDay()).replaceFirstChar { it.titlecase(Locale.getDefault()) }
    return if (ChronoUnit.DAYS.between(LocalDate.now(), date) == 1L) str(R.string.tomorrow_heading, text) else text
}

val weekdayNames: List<String> get() = listOf(str(R.string.mon), str(R.string.tue), str(R.string.wed), str(R.string.thu), str(R.string.fri), str(R.string.sat), str(R.string.sun))

fun every(freq: Freq, interval: UInt = 1u, weekdays: List<UInt> = emptyList()) = Repeat(
    freq = freq, interval = interval, weekdays = weekdays, monthday = null, nth = null,
    nthWeekday = null, fromDone = false, count = null, until = null,
)

val repeatPresets: List<Pair<String, Repeat>> get() = listOf(
    str(R.string.every_day) to every(Freq.DAILY),
    str(R.string.weekdays) to every(Freq.WEEKLY, weekdays = listOf(1u, 2u, 3u, 4u, 5u)),
    str(R.string.every_week) to every(Freq.WEEKLY),
    str(R.string.every_two_weeks) to every(Freq.WEEKLY, interval = 2u),
    str(R.string.every_month) to every(Freq.MONTHLY),
    str(R.string.every_quarter) to every(Freq.MONTHLY, interval = 3u),
    str(R.string.every_year) to every(Freq.YEARLY),
)

fun Repeat.presetName(): String? {
    if (nth != null || fromDone || count != null || until != null) return null
    // The day of month is filled in by the core and does not make the rule custom.
    val shape = copy(monthday = null)
    return repeatPresets.firstOrNull { it.second == shape }?.first
}

fun Repeat.summary(): String {
    presetName()?.let { return it }
    val n = interval
    var text = when (freq) {
        Freq.DAILY -> if (n == 1u) str(R.string.every_day) else str(R.string.every_n_days, n)
        Freq.WEEKLY -> {
            val base = if (n == 1u) str(R.string.every_week) else str(R.string.every_n_weeks, n)
            val days = weekdays.sorted().mapNotNull { weekdayNames.getOrNull(it.toInt() - 1) }
            if (days.isEmpty()) base else "$base: ${days.joinToString(", ")}"
        }
        Freq.MONTHLY -> {
            val base = if (n == 1u) str(R.string.every_month) else str(R.string.every_n_months, n)
            val which = nth
            val weekday = nthWeekday?.let { weekdayNames.getOrNull(it.toInt() - 1) }
            when {
                which != null && weekday != null -> "$base, ${if (which < 0) lastWord() else ordinal(which)} $weekday"
                monthday != null -> str(R.string.base_on_monthday, base, monthday)
                else -> base
            }
        }
        Freq.YEARLY -> if (n == 1u) str(R.string.every_year) else str(R.string.every_n_years, n)
    }
    if (fromDone) text += str(R.string.after_completion)
    count?.let { text += str(R.string.n_left, it) }
    until?.let { text += str(R.string.until_suffix, dateLabel(it).lowercase()) }
    return text
}

private fun lastWord() = str(R.string.last)

val priorities = listOf(Priority.NONE, Priority.LOW, Priority.MEDIUM, Priority.HIGH)

fun Priority.title(): String = when (this) {
    Priority.NONE -> str(R.string.prio_none)
    Priority.LOW -> str(R.string.prio_low)
    Priority.MEDIUM -> str(R.string.prio_medium)
    Priority.HIGH -> str(R.string.prio_high)
}

fun Priority.marks(): String = when (this) {
    Priority.NONE -> ""
    Priority.LOW -> "!"
    Priority.MEDIUM -> "!!"
    Priority.HIGH -> "!!!"
}

fun TaskList.displayName(): String = if (id == "inbox") str(R.string.inbox) else name

val listColors = listOf("", "#E5484D", "#F2994A", "#E2B93B", "#3FB950", "#2BB3A3", "#2F6FED", "#6E56CF", "#B658C4", "#8B8D98")
