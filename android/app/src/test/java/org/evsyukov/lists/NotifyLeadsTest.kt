package org.evsyukov.lists

import org.junit.Assert.assertEquals
import org.junit.Test

class NotifyLeadsTest {
    @Test
    fun r36_without_a_choice_the_reminder_comes_at_the_time() {
        assertEquals(listOf(0), NotifyPrefs.storedLeads(saved = null, legacy = null, moved = false))
        assertEquals(listOf(0), NotifyPrefs.storedLeads(saved = null, legacy = null, moved = true))
    }

    @Test
    fun r36_the_old_default_becomes_at_the_time_once() {
        assertEquals(listOf(0), NotifyPrefs.storedLeads(saved = "15", legacy = null, moved = false))
        assertEquals(listOf(0), NotifyPrefs.storedLeads(saved = null, legacy = 15, moved = false))
    }

    @Test
    fun r36_fifteen_minutes_chosen_after_the_update_stay() {
        assertEquals(listOf(15), NotifyPrefs.storedLeads(saved = "15", legacy = null, moved = true))
    }

    @Test
    fun r36_any_other_choice_is_left_alone() {
        assertEquals(listOf(15, 60), NotifyPrefs.storedLeads(saved = "15,60", legacy = null, moved = false))
        assertEquals(listOf(5), NotifyPrefs.storedLeads(saved = "5", legacy = 15, moved = false))
        assertEquals(emptyList<Int>(), NotifyPrefs.storedLeads(saved = "", legacy = null, moved = false))
        assertEquals(emptyList<Int>(), NotifyPrefs.storedLeads(saved = null, legacy = -1, moved = false))
    }
}
