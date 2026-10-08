package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import uniffi.lists_core.KeepDone

class KeepDoneChoicesTest {
    private val offered = listOf(KeepDone.Seconds(0u), KeepDone.Seconds(5u), KeepDone.Seconds(15u), KeepDone.EndOfDay)

    @Test
    fun r68_offers_at_once_five_and_fifteen_seconds_and_the_end_of_the_day() {
        assertEquals(offered, keepDoneChoices(KeepDone.Seconds(5u)))
        assertEquals(offered, keepDoneChoices(KeepDone.EndOfDay))
    }

    @Test
    fun r68_minutes_chosen_in_an_earlier_version_stay_in_the_choice() {
        assertEquals(
            listOf(KeepDone.Seconds(0u), KeepDone.Seconds(5u), KeepDone.Seconds(15u), KeepDone.Seconds(900u), KeepDone.EndOfDay),
            keepDoneChoices(KeepDone.Seconds(900u)),
        )
    }
}
