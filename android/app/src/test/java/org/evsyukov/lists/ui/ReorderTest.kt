package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.lists_core.Priority
import uniffi.lists_core.Scope
import uniffi.lists_core.SortMode
import uniffi.lists_core.TaskList

class ReorderTest {
    private fun list(id: String, sort: SortMode) = TaskList(id, id, "", "", sort, false, Priority.NONE, false, false, 0u)

    private val state = UiState(lists = listOf(list("inbox", SortMode.MANUAL), list("home", SortMode.MANUAL), list("work", SortMode.DUE)))

    @Test
    fun r157_rows_are_put_in_order_by_hand_in_inbox_and_in_a_list_sorted_by_hand() {
        assertTrue(state.copy(scope = Scope.Inbox).reorderable())
        assertTrue(state.copy(scope = Scope.List("home")).reorderable())
        assertFalse("a list sorted by due date", state.copy(scope = Scope.List("work")).reorderable())
        assertFalse(state.copy(scope = Scope.Today).reorderable())
        assertFalse(state.copy(scope = Scope.Project("trip")).reorderable())
        assertFalse(state.copy(scope = Scope.Inbox, search = "milk").reorderable())
        assertFalse(state.copy(scope = Scope.Inbox, selection = emptySet()).reorderable())
    }

    @Test
    fun r157_a_moved_row_goes_right_after_the_row_now_above_it() {
        val order = listOf("a", "b", "c", "d")
        assertEquals(listOf("b", "c", "a", "d"), order.moved(0, 2))
        assertEquals(listOf("d", "a", "b", "c"), order.moved(3, 0))
        assertEquals(order, order.moved(1, 1))
        assertEquals("c", placedAfter(order.moved(0, 2), "a"))
        assertEquals("first: after nothing", null, placedAfter(order.moved(3, 0), "d"))
    }

    @Test
    fun r157_a_list_lands_by_whole_rows_and_the_rows_between_make_room() {
        assertEquals(2, landing(0, 120f, 56f, 4))
        assertEquals("past half a row", 1, landing(0, 30f, 56f, 4))
        assertEquals(0, landing(0, 20f, 56f, 4))
        assertEquals("not beyond the last", 3, landing(1, 500f, 56f, 4))
        assertEquals(0, landing(2, -500f, 56f, 4))
        // The row at 0 dragged to 2: rows 1 and 2 move up one row, row 3 stays.
        assertEquals(listOf(0, -1, -1, 0), (0..3).map { shiftOf(it, 0, 2) })
        assertEquals(listOf(1, 1, 0, 0), (0..3).map { shiftOf(it, 2, 0) })
    }

    @Test
    fun r157_a_long_press_let_go_in_place_is_not_a_drag() {
        val reorder = Reorder()
        reorder.start("a", listOf("a", "b"))
        assertEquals(Dropped.Still, reorder.drop(slop = 8f))
        assertEquals(null, reorder.dragging)
        assertEquals(null, reorder.order)
    }

    @Test
    fun r157_a_row_dragged_back_to_its_place_is_not_moved() {
        val reorder = Reorder()
        reorder.start("a", listOf("a", "b"))
        assertEquals(Dropped.Kept, reorder.drop(slop = 0f))
    }

    @Test
    fun r157_a_row_held_at_an_edge_scrolls_the_column_faster_the_closer_it_is() {
        // A column from 0 to 1000, rows 100 high: the strips are 0–100 and 900–1000.
        assertEquals(0f, edgeStep(top = 400f, size = 100f, start = 0f, end = 1000f), 0f)
        assertEquals(12.5f, edgeStep(top = 850f, size = 100f, start = 0f, end = 1000f), 0.001f)
        assertEquals(25f, edgeStep(top = 900f, size = 100f, start = 0f, end = 1000f), 0.001f)
        assertEquals(25f, edgeStep(top = 990f, size = 100f, start = 0f, end = 1000f), 0.001f)
        assertEquals(-12.5f, edgeStep(top = 50f, size = 100f, start = 0f, end = 1000f), 0.001f)
        assertEquals(-25f, edgeStep(top = -20f, size = 100f, start = 0f, end = 1000f), 0.001f)
    }
}
