package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import uniffi.lists_core.Freq
import uniffi.lists_core.Repeat

class RepeatEndTest {
    private fun rule(count: UInt? = null, until: String? = null) =
        Repeat(Freq.WEEKLY, 1u, emptyList(), null, null, null, false, count, until)

    @Test
    fun r15_the_dialog_opens_on_the_ending_the_rule_has() {
        assertEquals(RepeatEnd.Never, null.ending())
        assertEquals(RepeatEnd.Never, rule().ending())
        assertEquals(RepeatEnd.Count, rule(count = 4u).ending())
        assertEquals(RepeatEnd.Date, rule(until = "2026-12-31").ending())
    }

    @Test
    fun r15_only_the_chosen_ending_is_kept() {
        assertEquals(null to null, repeatEnd(RepeatEnd.Never, "4", "2026-12-31"))
        assertEquals(4u to null, repeatEnd(RepeatEnd.Count, "4", "2026-12-31"))
        assertEquals(null to "2026-12-31", repeatEnd(RepeatEnd.Date, "4", "2026-12-31"))
    }

    @Test
    fun r15_an_end_date_is_a_day_and_a_count_is_a_positive_number() {
        assertEquals(null to "2026-12-31", repeatEnd(RepeatEnd.Date, "", "2026-12-31T09:00"))
        assertEquals(null to null, repeatEnd(RepeatEnd.Count, "", null))
        assertEquals(null to null, repeatEnd(RepeatEnd.Count, "0", null))
    }
}
