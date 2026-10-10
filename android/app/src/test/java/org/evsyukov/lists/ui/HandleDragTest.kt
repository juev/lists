package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HandleDragTest {
    private val slop = 21f

    @Test
    fun r97_a_move_inside_the_slop_asks_nothing() {
        assertNull(handleDrag(-21f, slop, expanded = false))
        assertNull(handleDrag(21f, slop, expanded = true))
        assertNull(handleDrag(0f, slop, expanded = false))
    }

    @Test
    fun r97_r99_a_drag_up_expands() {
        assertEquals(HandleDrag.Expand, handleDrag(-22f, slop, expanded = false))
        assertEquals(HandleDrag.Expand, handleDrag(-300f, slop, expanded = true))
    }

    @Test
    fun r97_r99_a_drag_down_collapses_an_expanded_card_and_does_not_close_it() {
        assertEquals(HandleDrag.Collapse, handleDrag(22f, slop, expanded = true))
    }

    @Test
    fun r97_r99_a_drag_down_closes_a_card_that_is_not_expanded() {
        assertEquals(HandleDrag.Close, handleDrag(22f, slop, expanded = false))
    }
}
