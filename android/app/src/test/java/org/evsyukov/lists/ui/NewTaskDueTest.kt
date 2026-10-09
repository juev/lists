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

    @Test
    fun r64_the_card_shows_the_picked_due_then_the_typed_then_the_preset() {
        assertEquals(tomorrow, shownDue(picked = tomorrow, typed = today, preset = today))
        assertEquals(tomorrow, shownDue(picked = null, typed = tomorrow, preset = today))
        assertEquals(today, shownDue(picked = null, typed = null, preset = today))
        assertNull(shownDue(picked = null, typed = null, preset = null))
    }

    @Test
    fun r64_the_card_shows_the_priority_the_task_will_get() {
        // Untouched: the title wins over the default of the list (R41).
        assertEquals(Priority.MEDIUM, shownPriority(picked = null, typed = Priority.MEDIUM, preset = Priority.HIGH))
        assertEquals(Priority.HIGH, shownPriority(picked = null, typed = Priority.NONE, preset = Priority.HIGH))
        assertEquals(Priority.NONE, shownPriority(picked = null, typed = Priority.NONE, preset = null))
        // "None" takes the default of the list away and leaves what the title names (R75).
        assertEquals(Priority.MEDIUM, shownPriority(picked = Priority.NONE, typed = Priority.MEDIUM, preset = null))
        assertEquals(Priority.NONE, shownPriority(picked = Priority.NONE, typed = Priority.NONE, preset = null))
        assertEquals(Priority.LOW, shownPriority(picked = Priority.LOW, typed = Priority.HIGH, preset = null))
    }

    @Test
    fun r64_what_the_card_shows_is_what_the_task_gets() {
        for (picked in listOf(null, Priority.NONE, Priority.LOW)) {
            for (typed in listOf(Priority.NONE, Priority.MEDIUM)) {
                // The core gives a new task the priority of its title, which is what `created` holds here.
                assertEquals(finalPriority(picked, created = typed, typed = typed), shownPriority(picked, typed, preset = null))
            }
        }
    }
}
