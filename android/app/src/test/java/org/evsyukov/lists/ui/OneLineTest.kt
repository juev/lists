package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class OneLineTest {
    @Test
    fun r73_enter_at_the_end_or_in_the_middle_leaves_the_title_as_it_was() {
        assertEquals("Buy milk", oneLine("Buy milk", "Buy milk\n"))
        assertEquals("Buy milk", oneLine("Buy milk", "Buy\n milk"))
    }

    @Test
    fun r73_pasted_lines_become_one_line() {
        assertEquals("Buy milk and bread today", oneLine("Buy ", "Buy milk\nand bread\n\n  today\n"))
    }
}
