package org.evsyukov.lists

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import uniffi.lists_core.Scope

class TaskWidgetTest {
    @Test
    fun r107_the_choice_of_a_widget_survives_being_stored() {
        for (view in listOf(WidgetView.Today, WidgetView.Inbox, WidgetView.OfList("work"), WidgetView.OfList("a:b"))) {
            assertEquals(view, WidgetView.decode(view.encode()))
        }
    }

    @Test
    fun r107_a_widget_without_a_choice_shows_nothing() {
        assertNull(WidgetView.decode(null))
        assertNull(WidgetView.decode(""))
        assertNull(WidgetView.decode("list:"))
        assertNull(WidgetView.decode("upcoming"))
    }

    @Test
    fun r107_each_choice_opens_its_own_view() {
        assertEquals(Scope.Today, WidgetView.Today.scope)
        assertEquals(Scope.Inbox, WidgetView.Inbox.scope)
        assertEquals(Scope.List("work"), WidgetView.OfList("work").scope)
    }

    @Test
    fun r107_a_higher_widget_holds_more_rows() {
        // 40 dp of header, 16 dp of padding, 32 dp a row.
        assertEquals(1, TaskWidgets.rowsThatFit(88))
        assertEquals(2, TaskWidgets.rowsThatFit(120))
        assertEquals(6, TaskWidgets.rowsThatFit(250))
        assertEquals(6, TaskWidgets.rowsThatFit(279))
        assertEquals(7, TaskWidgets.rowsThatFit(280))
    }

    @Test
    fun r107_a_widget_too_low_for_a_row_still_shows_one() {
        assertEquals(1, TaskWidgets.rowsThatFit(0))
        assertEquals(1, TaskWidgets.rowsThatFit(40))
    }

    @Test
    fun r107_tasks_that_fit_are_all_shown() {
        assertEquals(emptyList<String>() to 0, TaskWidgets.shown(emptyList<String>(), 3))
        assertEquals(listOf("a", "b", "c") to 0, TaskWidgets.shown(listOf("a", "b", "c"), 3))
    }

    @Test
    fun r107_past_what_fits_the_last_row_counts_the_rest() {
        assertEquals(listOf("a", "b") to 2, TaskWidgets.shown(listOf("a", "b", "c", "d"), 3))
        assertEquals(emptyList<String>() to 2, TaskWidgets.shown(listOf("a", "b"), 1))
    }

    @Test
    fun r107_today_puts_overdue_tasks_first_and_keeps_the_order_inside_each_group() {
        val due = mapOf("a" to "2026-10-10", "b" to "2026-10-09", "c" to null, "d" to "2026-10-08T09:00", "e" to "2026-10-10T18:00")
        assertEquals(
            listOf("b", "d", "a", "c", "e"),
            TaskWidgets.overdueFirst(listOf("a", "b", "c", "d", "e"), { due[it] }, today = "2026-10-10"),
        )
    }
}
