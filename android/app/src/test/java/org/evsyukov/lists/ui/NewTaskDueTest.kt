package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import uniffi.lists_core.Priority

class NewTaskDueTest {
    private val today = "2026-10-08"
    private val tomorrow = "2026-10-09"

    @Test
    fun r75_list_with_default_due_presets_today_unless_a_start_is_set() {
        assertEquals(today, presetDue(listDueToday = true, start = null, today = today))
        assertNull(presetDue(listDueToday = true, start = tomorrow, today = today))
    }

    @Test
    fun r75_no_preset_without_a_list_default() {
        assertNull(presetDue(listDueToday = false, start = null, today = today))
    }

    @Test
    fun r75_untouched_priority_keeps_what_the_core_set() {
        assertEquals(Priority.HIGH, finalPriority(picked = null, created = Priority.HIGH, typed = Priority.NONE))
        assertEquals(Priority.NONE, finalPriority(picked = null, created = Priority.NONE, typed = Priority.NONE))
    }

    @Test
    fun r41_chosen_priority_wins_over_the_title_and_the_list() {
        assertEquals(Priority.LOW, finalPriority(picked = Priority.LOW, created = Priority.HIGH, typed = Priority.HIGH))
    }

    @Test
    fun r75_removed_priority_leaves_none_even_when_the_list_gave_one() {
        assertEquals(Priority.NONE, finalPriority(picked = Priority.NONE, created = Priority.HIGH, typed = Priority.NONE))
    }

    @Test
    fun r75_removed_priority_keeps_the_priority_of_the_title() {
        assertEquals(Priority.MEDIUM, finalPriority(picked = Priority.NONE, created = Priority.MEDIUM, typed = Priority.MEDIUM))
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
    fun r75_preset_date_is_set_when_the_core_gave_none() {
        assertEquals(today, finalDue(due = today, isPreset = true, removed = false, created = null, typed = null))
    }

    @Test
    fun r75_removed_preset_leaves_no_date_even_when_the_list_gave_one() {
        assertNull(finalDue(due = null, isPreset = false, removed = true, created = today, typed = null))
    }

    @Test
    fun r75_removed_preset_keeps_the_date_of_the_title() {
        assertEquals(tomorrow, finalDue(due = null, isPreset = false, removed = true, created = tomorrow, typed = tomorrow))
    }

    @Test
    fun untouched_empty_field_keeps_what_the_core_set() {
        assertEquals(today, finalDue(due = null, isPreset = false, removed = false, created = today, typed = null))
        assertNull(finalDue(due = null, isPreset = false, removed = false, created = null, typed = null))
    }
}
