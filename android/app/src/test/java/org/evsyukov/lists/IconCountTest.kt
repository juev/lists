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

    @Test
    fun r106_the_update_turns_the_list_on_for_a_person_who_had_only_the_count() {
        assertEquals(true, IconCount.turnsListOn("today", listOn = false, merged = false))
        assertEquals(true, IconCount.turnsListOn("overdue", listOn = false, merged = false))
    }

    @Test
    fun r106_the_update_leaves_the_list_alone_otherwise() {
        assertEquals(false, IconCount.turnsListOn("none", listOn = false, merged = false))
        assertEquals(false, IconCount.turnsListOn("today", listOn = true, merged = false))
        // Once: a person who turns the list off after the update keeps it off.
        assertEquals(false, IconCount.turnsListOn("today", listOn = false, merged = true))
    }
}
