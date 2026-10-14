package org.evsyukov.lists

import org.junit.Assert.assertEquals
import org.junit.Test

class AlarmWayTest {
    @Test
    fun r119_off_by_default_leaves_the_exact_alarm() {
        assertEquals(Reminders.Way.EXACT, Reminders.way(exact = true, asAlarmClock = false))
    }

    @Test
    fun r119_switched_on_sets_an_alarm_of_the_person() {
        assertEquals(Reminders.Way.ALARM_CLOCK, Reminders.way(exact = true, asAlarmClock = true))
    }

    @Test
    fun r119_without_the_leave_the_alarm_stays_inexact() {
        assertEquals(Reminders.Way.INEXACT, Reminders.way(exact = false, asAlarmClock = true))
        assertEquals(Reminders.Way.INEXACT, Reminders.way(exact = false, asAlarmClock = false))
    }
}
