package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NewTaskDueTest {
    private val today = "2026-10-08"
    private val tomorrow = "2026-10-09"

    @Test
    fun r57_today_view_presets_its_date() {
        assertEquals(today, presetDue(viewDue = today, listDueToday = false, start = null, today = today))
        assertEquals(today, presetDue(viewDue = today, listDueToday = false, start = tomorrow, today = today))
    }

    @Test
    fun r57_list_with_default_due_presets_today_unless_a_start_is_set() {
        assertEquals(today, presetDue(viewDue = null, listDueToday = true, start = null, today = today))
        assertNull(presetDue(viewDue = null, listDueToday = true, start = tomorrow, today = today))
    }

    @Test
    fun r57_no_preset_without_a_view_date_or_a_list_default() {
        assertNull(presetDue(viewDue = null, listDueToday = false, start = null, today = today))
    }

    @Test
    fun r41_picked_date_wins_over_the_title() {
        assertEquals(today, finalDue(due = today, isPreset = false, removed = false, created = tomorrow, typed = tomorrow))
    }

    @Test
    fun r41_preset_date_yields_to_the_title() {
        assertEquals(tomorrow, finalDue(due = today, isPreset = true, removed = false, created = tomorrow, typed = tomorrow))
    }

    @Test
    fun r57_preset_date_is_set_when_the_core_gave_none() {
        assertEquals(today, finalDue(due = today, isPreset = true, removed = false, created = null, typed = null))
    }

    @Test
    fun r57_removed_preset_leaves_no_date_even_when_the_list_gave_one() {
        assertNull(finalDue(due = null, isPreset = false, removed = true, created = today, typed = null))
    }

    @Test
    fun r57_removed_preset_keeps_the_date_of_the_title() {
        assertEquals(tomorrow, finalDue(due = null, isPreset = false, removed = true, created = tomorrow, typed = tomorrow))
    }

    @Test
    fun untouched_empty_field_keeps_what_the_core_set() {
        assertEquals(today, finalDue(due = null, isPreset = false, removed = false, created = today, typed = null))
        assertNull(finalDue(due = null, isPreset = false, removed = false, created = null, typed = null))
    }
}
