package org.evsyukov.lists

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RowDateTest {
    private val label: (String) -> String = { "day of $it" }
    private val today = today()
    private val yesterday = plusDays(-1)

    @Test
    fun r72_no_due_date_leaves_the_right_edge_empty() {
        assertNull(rowDate(null, open = true, dayInHeading = false, label = label))
    }

    @Test
    fun r72_a_day_the_heading_names_is_not_written_and_the_time_stays() {
        assertNull(rowDate(today, open = true, dayInHeading = true, label = label))
        // A day ahead, as under a day of Upcoming: a time of today would be late for a part of the day.
        assertEquals("09:00" to false, rowDate("${plusDays(1)}T09:00", open = true, dayInHeading = true, label = label))
    }

    @Test
    fun r72_without_a_heading_for_the_day_the_date_is_written() {
        assertEquals("day of $today" to false, rowDate(today, open = true, dayInHeading = false, label = label))
    }

    @Test
    fun r72_an_overdue_date_is_written_with_its_day_and_marked_late_even_under_a_heading() {
        assertEquals("day of $yesterday" to true, rowDate(yesterday, open = true, dayInHeading = true, label = label))
        assertEquals("00:00" to true, rowDate("${today}T00:00", open = true, dayInHeading = true, label = label))
    }

    @Test
    fun r72_a_completed_task_is_never_late() {
        assertEquals("day of $yesterday" to false, rowDate(yesterday, open = false, dayInHeading = false, label = label))
    }
}
