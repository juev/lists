package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SwipeTest {
    @Test
    fun r132_a_swipe_acts_only_past_forty_percent_of_the_row() {
        assertNull("short of the threshold", swipeAction(399f, 1000f))
        assertEquals(Swipe.Complete, swipeAction(400f, 1000f))
        assertEquals(Swipe.Complete, swipeAction(900f, 1000f))
        assertNull(swipeAction(-399f, 1000f))
        assertEquals(Swipe.Due, swipeAction(-400f, 1000f))
    }

    @Test
    fun r132_a_row_not_measured_yet_takes_no_swipe() {
        assertNull(swipeAction(50f, 0f))
    }
}
