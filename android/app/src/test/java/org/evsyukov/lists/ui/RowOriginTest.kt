package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Test
import uniffi.lists_core.Priority

class RowOriginTest {
    @Test
    fun r72_a_task_of_a_list_carries_the_name_and_the_colour_of_the_list() {
        val origin = rowOrigin("Home", "#ff3b30", project = null)
        assertEquals(RowOrigin("Home", "#ff3b30", null), origin)
        assertEquals("Home", origin?.label)
    }

    @Test
    fun r72_a_task_of_the_inbox_carries_the_name_of_the_inbox() {
        // The Inbox has no colour in the data: the name is drawn in the colour of the app.
        assertEquals(RowOrigin("Inbox", null, null), rowOrigin("Inbox", "", project = null))
    }

    @Test
    fun r72_a_task_of_a_project_carries_the_list_and_the_project() {
        assertEquals("Home – Repair", rowOrigin("Home", "#ff3b30", project = "Repair")?.label)
        assertEquals("Inbox – Trip", rowOrigin("Inbox", "", project = "Trip")?.label)
    }

    @Test
    fun r72_a_list_that_is_not_known_gives_no_name() {
        assertNull(rowOrigin(null, null, project = null))
        assertEquals(RowOrigin(null, null, "Trip"), rowOrigin(null, "#ff3b30", project = "Trip"))
    }

    @Test
    fun r72_the_bar_has_a_colour_of_its_own_for_each_priority_and_none_without_one() {
        assertNull(priorityBarColor(Priority.NONE))
        val colours = listOf(Priority.LOW, Priority.MEDIUM, Priority.HIGH).map(::priorityBarColor)
        colours.forEach(::assertNotNull)
        assertEquals(3, colours.toSet().size)
    }
}
