package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class NoteLinesTest {
    @Test
    fun r64_compact_note_starts_at_one_line_and_grows_to_five() {
        assertEquals(1..5, noteLines(full = false, landscape = false))
    }

    @Test
    fun r64_expanded_note_has_no_upper_bound() {
        assertEquals(4..Int.MAX_VALUE, noteLines(full = true, landscape = false))
        assertEquals(2..Int.MAX_VALUE, noteLines(full = true, landscape = true))
    }
}
