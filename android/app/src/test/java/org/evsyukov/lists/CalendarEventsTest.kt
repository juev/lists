package org.evsyukov.lists

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset

class CalendarEventsTest {
    private val today = LocalDate.of(2026, 10, 8)
    private val moscow = ZoneId.of("Europe/Moscow")
    private val newYork = ZoneId.of("America/New_York")

    private fun at(zone: ZoneId, day: LocalDate, hour: Int, minute: Int = 0) =
        LocalDateTime.of(day, java.time.LocalTime.of(hour, minute)).atZone(zone).toInstant().toEpochMilli()

    private fun timed(title: String, zone: ZoneId, day: LocalDate, hour: Int, minute: Int = 0, hours: Long = 1) =
        RawEvent(title.hashCode().toLong(), title, at(zone, day, hour, minute), at(zone, day, hour, minute) + hours * 3600_000, false, 0)

    /** The system keeps an all-day event on UTC midnights. */
    private fun allDay(title: String, day: LocalDate, days: Long = 1) = RawEvent(
        title.hashCode().toLong(), title,
        day.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(),
        day.plusDays(days).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(), true, 0,
    )

    private fun lines(events: List<RawEvent>, zone: ZoneId) =
        arrangeEvents(events, today, zone).map { listOfNotNull(it.time, it.title).joinToString(" ") }

    @Test
    fun r78_all_day_events_come_first_then_timed_ones_by_their_start() {
        val events = listOf(
            timed("Bank", moscow, today, 14, 30),
            allDay("Birthday", today),
            timed("Standup", moscow, today, 9),
        )
        assertEquals(listOf("Birthday", "09:00 Standup", "14:30 Bank"), lines(events, moscow))
    }

    @Test
    fun r78_the_title_settles_events_that_start_together() {
        val events = listOf(
            timed("standup", moscow, today, 9),
            timed("Alpha", moscow, today, 9),
            allDay("Trip", today),
            allDay("birthday", today),
        )
        assertEquals(listOf("birthday", "Trip", "09:00 Alpha", "09:00 standup"), lines(events, moscow))
    }

    @Test
    fun r78_an_event_that_began_before_today_has_no_time_and_stands_with_the_all_day_ones() {
        val events = listOf(
            timed("Standup", moscow, today, 9),
            timed("Night shift", moscow, today.minusDays(1), 22, hours = 8),
        )
        assertEquals(listOf("Night shift", "09:00 Standup"), lines(events, moscow))
    }

    @Test
    fun r78_an_event_that_has_ended_today_stays() {
        assertEquals(listOf("00:00 Midnight"), lines(listOf(timed("Midnight", moscow, today, 0, hours = 0)), moscow))
    }

    @Test
    fun r78_timed_events_of_other_days_are_left_out() {
        val events = listOf(
            timed("Yesterday", moscow, today.minusDays(1), 23, hours = 1),
            timed("Tomorrow", moscow, today.plusDays(1), 0),
            timed("Late", moscow, today, 23, 30),
        )
        assertEquals(listOf("23:30 Late"), lines(events, moscow))
    }

    @Test
    fun r78_an_all_day_event_belongs_to_its_own_day_east_and_west_of_utc() {
        val events = listOf(allDay("Yesterday", today.minusDays(1)), allDay("Today", today), allDay("Tomorrow", today.plusDays(1)))
        assertEquals(listOf("Today"), lines(events, moscow))
        assertEquals(listOf("Today"), lines(events, newYork))
    }

    @Test
    fun r78_an_all_day_event_of_several_days_is_shown_on_each_of_them() {
        val trip = allDay("Trip", today.minusDays(2), days = 3)
        assertEquals(listOf("Trip"), lines(listOf(trip), newYork))
        assertEquals(emptyList<String>(), lines(listOf(allDay("Trip", today.minusDays(3), days = 3)), moscow))
    }

    @Test
    fun r78_the_time_is_read_in_the_zone_of_the_device() {
        val event = timed("Call", moscow, today, 18)
        assertEquals(listOf("11:00 Call"), lines(listOf(event), newYork))
    }
}
