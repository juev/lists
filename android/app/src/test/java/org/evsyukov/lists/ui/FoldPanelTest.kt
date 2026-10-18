package org.evsyukov.lists.ui

import org.evsyukov.lists.LookPrefs
import org.junit.Assert.assertEquals
import org.junit.Test

class FoldPanelTest {
    @Test
    fun r158_a_folded_section_keeps_only_the_row_of_the_open_view() {
        val lists = listOf("work", "home", "trip")
        assertEquals(lists, shownRows(lists, folded = false) { it == "home" })
        assertEquals(listOf("home"), shownRows(lists, folded = true) { it == "home" })
        assertEquals(emptyList<String>(), shownRows(lists, folded = true) { false })
    }

    @Test
    fun r158_the_folded_sections_are_read_back_without_unknown_names() {
        assertEquals(emptySet<String>(), LookPrefs.foldedFrom(null))
        assertEquals(setOf("lists", "tags"), LookPrefs.foldedFrom(setOf("lists", "tags", "archive")))
    }

    @Test
    fun r158_the_rows_of_the_panel_follow_the_spacing() {
        assertEquals(listOf(48, 52, 56), LookPrefs.rowSpacings.map(LookPrefs::drawerRowHeight))
    }
}
