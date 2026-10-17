package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TypedEditTest {
    @Test
    fun r143_an_untouched_field_does_not_write_over_a_synced_edit() {
        // The cursor went in over "x"; a sync stored "y" meanwhile; nothing was typed.
        assertNull(typedEdit("x", shown = "x", stored = "y"))
    }

    @Test
    fun r143_spaces_alone_are_not_an_edit() {
        assertNull(typedEdit("x \n", shown = "x", stored = "y"))
    }

    @Test
    fun r143_a_text_typed_and_taken_back_is_not_an_edit() {
        // "x" → "xa" → "x": the field ends where it began.
        assertNull(typedEdit("  x", shown = "x ", stored = "y"))
    }

    @Test
    fun r143_what_was_typed_wins_over_a_synced_edit() {
        assertEquals("z", typedEdit("z ", shown = "x", stored = "y"))
    }

    @Test
    fun r143_an_edit_with_no_sync_in_between_is_written() {
        assertEquals("xz", typedEdit("xz", shown = "x", stored = "x"))
    }

    @Test
    fun r143_a_text_equal_to_what_is_stored_is_not_written_again() {
        assertNull(typedEdit("y", shown = "x", stored = "y"))
    }
}
