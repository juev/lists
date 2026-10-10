package org.evsyukov.lists

import org.junit.Assert.assertEquals
import org.junit.Test

class IconCountTest {
    @Test
    fun r106_today_counts_the_tasks_of_today() {
        assertEquals(2, IconCount.number("today", today = 2u, overdue = 1u))
    }

    @Test
    fun r106_overdue_counts_the_overdue_tasks_only() {
        assertEquals(1, IconCount.number("overdue", today = 2u, overdue = 1u))
    }

    @Test
    fun r106_none_counts_nothing() {
        assertEquals(0, IconCount.number("none", today = 2u, overdue = 1u))
    }

    @Test
    fun r106_nothing_to_count_gives_no_number() {
        assertEquals(0, IconCount.number("today", today = 0u, overdue = 0u))
        assertEquals(0, IconCount.number("overdue", today = 3u, overdue = 0u))
    }
}
