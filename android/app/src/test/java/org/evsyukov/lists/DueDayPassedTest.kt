package org.evsyukov.lists

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DueDayPassedTest {
    private val today = "2026-10-08"

    @Test
    fun r84_a_due_day_before_today_is_overdue() {
        assertTrue(dueDayPassed("2026-10-07", today))
        assertTrue(dueDayPassed("2026-10-07T23:59", today))
    }

    @Test
    fun r84_a_task_without_a_due_date_is_not_overdue_whatever_its_start() {
        assertFalse(dueDayPassed(null, today))
    }

    @Test
    fun r84_a_due_date_of_today_or_later_is_not_overdue_even_with_a_time_that_has_passed() {
        assertFalse(dueDayPassed("2026-10-08", today))
        assertFalse(dueDayPassed("2026-10-08T00:00", today))
        assertFalse(dueDayPassed("2026-10-09", today))
    }
}
