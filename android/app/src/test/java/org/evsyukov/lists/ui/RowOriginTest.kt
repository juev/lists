package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RowOriginTest {
    @Test
    fun r72_a_task_of_a_list_carries_the_name_and_the_colour_of_the_list() {
        val origin = rowOrigin("home", "Home", "#ff3b30", project = null)
        assertEquals(RowOrigin("Home", "#ff3b30", null), origin)
        assertEquals("Home", origin?.label)
    }

    @Test
    fun r72_a_task_of_the_inbox_carries_nothing() {
        assertNull(rowOrigin("inbox", "Inbox", "#888888", project = null))
    }

    @Test
    fun r72_a_task_of_a_project_carries_the_list_and_the_project() {
        assertEquals("Home – Repair", rowOrigin("home", "Home", "#ff3b30", project = "Repair")?.label)
    }

    @Test
    fun r72_a_task_of_a_project_in_the_inbox_carries_the_project_alone() {
        val origin = rowOrigin("inbox", "Inbox", "#888888", project = "Trip")
        assertEquals(RowOrigin(null, null, "Trip"), origin)
        assertEquals("Trip", origin?.label)
    }

    @Test
    fun r72_a_list_that_is_not_known_gives_no_name() {
        assertNull(rowOrigin("gone", null, null, project = null))
    }
}
