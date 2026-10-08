package org.evsyukov.lists

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDate
import java.util.TimeZone

class MomentTest {
    private val day = LocalDate.of(2026, 10, 20)

    @Test
    fun r74_day_of_the_calendar_with_a_time_is_one_moment() {
        assertEquals("2026-10-20T18:30", momentString(pickerDay(pickerMillis(day)), 18, 30))
        assertEquals("2026-10-20", momentString(pickerDay(pickerMillis(day)), null, null))
    }

    @Test
    fun r74_day_of_the_calendar_does_not_move_with_the_zone_of_the_device() {
        val zone = TimeZone.getDefault()
        try {
            for (id in listOf("Pacific/Kiritimati", "Pacific/Pago_Pago", "UTC")) {
                TimeZone.setDefault(TimeZone.getTimeZone(id))
                assertEquals(1_792_454_400_000, pickerMillis(day))
                assertEquals(day, pickerDay(1_792_454_400_000))
                // The picker hands back the start of the day, but any moment of it is that day.
                assertEquals(day, pickerDay(1_792_454_400_000 + 86_399_999))
            }
        } finally {
            TimeZone.setDefault(zone)
        }
    }

    @Test
    fun r74_time_row_shows_the_time_of_the_task_only_when_it_has_one() {
        assertEquals("18:30", timeOf("2026-10-20T18:30"))
        assertNull(timeOf("2026-10-20"))
        assertNull(timeOf(null))
    }
}
