package org.evsyukov.lists

import org.junit.Assert.assertEquals
import org.junit.Test

class RowSpacingTest {
    @Test
    fun r122_nothing_saved_is_normal() {
        assertEquals("normal", LookPrefs.rowSpacingFrom(null))
    }

    @Test
    fun r122_a_saved_choice_is_kept() {
        for (choice in LookPrefs.rowSpacings) assertEquals(choice, LookPrefs.rowSpacingFrom(choice))
    }

    @Test
    fun r122_a_saved_value_that_is_not_a_choice_is_normal() {
        assertEquals("normal", LookPrefs.rowSpacingFrom("tight"))
    }

    @Test
    fun r122_rows_are_56_64_and_72_dp_high() {
        // The mark is a button with a touch target of 48 dp; the spacing lies above and below it (R159).
        val heights = LookPrefs.rowSpacings.map { 48 + 2 * LookPrefs.rowPadding(it) }
        assertEquals(listOf(56, 64, 72), heights)
    }
}
