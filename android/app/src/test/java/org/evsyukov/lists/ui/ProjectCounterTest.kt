package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class ProjectCounterTest {
    @Test
    fun r30_the_drawer_shows_done_over_total() {
        assertEquals("0/2", projectCounter(0u, 2u))
        assertEquals("1/3", projectCounter(1u, 3u))
        assertEquals("2/2", projectCounter(2u, 2u))
    }

    @Test
    fun r127_an_empty_project_shows_zero_over_zero() {
        assertEquals("0/0", projectCounter(0u, 0u))
    }
}
