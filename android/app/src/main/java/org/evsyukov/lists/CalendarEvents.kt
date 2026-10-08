package org.evsyukov.lists

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.CalendarContract
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/** An event of the day as the Today view shows it (R78). */
data class DayEvent(
    val key: String,
    val eventId: Long,
    val title: String,
    /** `HH:mm`; null for an all-day event and for one that began before today. */
    val time: String?,
    val color: Int,
    val begin: Long,
    val end: Long,
)

/** An event as the system gives it: the block is decided from this alone. Times are in milliseconds. */
data class RawEvent(
    val eventId: Long,
    val title: String,
    val begin: Long,
    val end: Long,
    val allDay: Boolean,
    val color: Int,
)

/** A calendar of the system, for the list in the settings. */
data class EventCalendar(val id: Long, val name: String, val account: String, val color: Int)

private val clock = DateTimeFormatter.ofPattern("HH:mm")

/**
 * The events of [today] in the order of the block: those without a time first, then the timed ones
 * by their start; the title settles a tie (R78).
 *
 * The system keeps an all-day event from midnight to midnight in UTC, whatever the zone of the
 * device, so its day is read in UTC; a timed event is of today when it touches the day in [zone].
 */
internal fun arrangeEvents(events: List<RawEvent>, today: LocalDate, zone: ZoneId): List<DayEvent> {
    val dayStart = today.atStartOfDay(zone).toInstant().toEpochMilli()
    val dayEnd = today.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
    fun utcDay(millis: Long) = Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate()
    val ofToday = events.filter { event ->
        if (event.allDay) {
            val first = utcDay(event.begin)
            // The end is the midnight after the last day; an event without a length takes its one day.
            val last = if (event.end > event.begin) utcDay(event.end - 1) else first
            today in first..last
        } else {
            event.begin < dayEnd && (event.end > dayStart || event.begin >= dayStart)
        }
    }
    fun shown(event: RawEvent, time: String?) = DayEvent(
        key = "${event.eventId}@${event.begin}", eventId = event.eventId, title = event.title,
        time = time, color = event.color, begin = event.begin, end = event.end,
    )
    val byTitle = compareBy<RawEvent, String>(String.CASE_INSENSITIVE_ORDER) { it.title }
    val (untimed, timed) = ofToday.partition { it.allDay || it.begin < dayStart }
    return untimed.sortedWith(byTitle).map { shown(it, null) } +
        timed.sortedWith(compareBy<RawEvent> { it.begin }.then(byTitle))
            .map { shown(it, Instant.ofEpochMilli(it.begin).atZone(zone).format(clock)) }
}

/** Calendar events in Today on this device (R78); not synced. */
object EventPrefs {
    private fun prefs(context: Context) = context.getSharedPreferences("events", Context.MODE_PRIVATE)

    /** Off until asked for: the permission is requested when this is turned on, not before. */
    fun enabled(context: Context) = prefs(context).getBoolean("enabled", false)
    fun setEnabled(context: Context, value: Boolean) = prefs(context).edit().putBoolean("enabled", value).apply()

    /** The calendars whose mark was taken off; a calendar that appears later is shown. */
    fun hidden(context: Context): Set<Long> =
        prefs(context).getStringSet("hidden", emptySet()).orEmpty().mapNotNull { it.toLongOrNull() }.toSet()
    fun setHidden(context: Context, value: Set<Long>) =
        prefs(context).edit().putStringSet("hidden", value.map { it.toString() }.toSet()).apply()
}

/** The calendars of the system, read only (R78). */
object SystemCalendars {
    private val _events = MutableStateFlow<List<DayEvent>>(emptyList())

    /** What the block of Today shows now; empty while the setting is off or the permission is missing. */
    val events: StateFlow<List<DayEvent>> = _events

    private val _readable = MutableStateFlow(false)

    /** True while the setting is on and the permission is given: only then is there something to watch. */
    val readable: StateFlow<Boolean> = _readable

    fun granted(context: Context) =
        context.checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED

    /** One reading at a time: the answer to an earlier request must not arrive after a later one. */
    private val reading = Mutex()

    suspend fun refresh(context: Context) = reading.withLock {
        val app = context.applicationContext
        val readable = EventPrefs.enabled(app) && granted(app)
        _readable.value = readable
        _events.value = withContext(Dispatchers.IO) {
            if (!readable) emptyList()
            else runCatching { arrangeEvents(read(app, EventPrefs.hidden(app)), LocalDate.now(), ZoneId.systemDefault()) }.getOrDefault(emptyList())
        }
    }

    fun calendars(context: Context): List<EventCalendar> {
        if (!granted(context)) return emptyList()
        val columns = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.CALENDAR_COLOR,
        )
        val found = mutableListOf<EventCalendar>()
        runCatching {
            context.contentResolver.query(CalendarContract.Calendars.CONTENT_URI, columns, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    found += EventCalendar(cursor.getLong(0), cursor.getString(1).orEmpty(), cursor.getString(2).orEmpty(), cursor.getInt(3))
                }
            }
        }
        return found.sortedWith(compareBy({ it.account }, { it.name }))
    }

    /** Wider than the day by the largest zone offset: an all-day event lies on UTC midnights. */
    private fun read(context: Context, hidden: Set<Long>): List<RawEvent> {
        val zone = ZoneId.systemDefault()
        val day = LocalDate.now()
        val margin = 18 * 3600_000L
        val from = day.atStartOfDay(zone).toInstant().toEpochMilli() - margin
        val to = day.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli() + margin
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon().let {
            ContentUris.appendId(it, from)
            ContentUris.appendId(it, to)
            it.build()
        }
        val columns = arrayOf(
            CalendarContract.Instances.EVENT_ID,
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.CALENDAR_COLOR,
            CalendarContract.Instances.CALENDAR_ID,
        )
        val found = mutableListOf<RawEvent>()
        context.contentResolver.query(uri, columns, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                if (cursor.getLong(6) in hidden) continue
                found += RawEvent(
                    eventId = cursor.getLong(0), title = cursor.getString(1).orEmpty(), begin = cursor.getLong(2),
                    end = cursor.getLong(3), allDay = cursor.getInt(4) != 0, color = cursor.getInt(5),
                )
            }
        }
        return found
    }

    /** Opens the event in the calendar app of the device. */
    fun view(event: DayEvent): Intent =
        Intent(Intent.ACTION_VIEW, ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, event.eventId))
            .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, event.begin)
            .putExtra(CalendarContract.EXTRA_EVENT_END_TIME, event.end)
}
