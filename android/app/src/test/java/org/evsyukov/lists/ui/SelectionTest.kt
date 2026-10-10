package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.lists_core.Priority
import uniffi.lists_core.Repeat
import uniffi.lists_core.TaskItem

class SelectionTest {
    private fun task(
        id: String = "a",
        listId: String = "inbox",
        parentId: String? = null,
        start: String? = null,
        due: String? = null,
        priority: Priority = Priority.NONE,
        tags: List<String> = emptyList(),
        repeat: Repeat? = null,
        done: String? = null,
        deleted: Boolean = false,
        isLog: Boolean = false,
    ) = TaskItem(
        id, listId, parentId, null, id, "", start, due, priority, tags, repeat, null, done,
        false, deleted, isLog, false, 0u, 0u, 0u,
    )

    @Test
    fun r109_a_row_can_be_selected_unless_it_is_in_the_trash_or_a_record() {
        assertTrue(task().selectable())
        assertTrue(task(done = "2026-10-10T10:00").selectable())
        assertFalse(task(deleted = true).selectable())
        assertFalse(task(isLog = true).selectable())
    }

    @Test
    fun r109_completing_is_taken_back_by_reopening() {
        assertEquals(Step(Back.Reopen), BatchAction.Complete.on(task()))
        assertEquals(Step(Back.Reopen), BatchAction.WontDo.on(task()))
    }

    @Test
    fun r109_a_closed_task_is_passed_over_when_completing() {
        assertNull(BatchAction.Complete.on(task(done = "2026-10-10T10:00")))
        assertNull(BatchAction.WontDo.on(task(done = "2026-10-10T10:00")))
    }

    @Test
    fun r109_deleting_is_taken_back_by_restoring_also_for_a_closed_task() {
        assertEquals(Step(Back.Restore), BatchAction.Delete.on(task()))
        assertEquals(Step(Back.Restore), BatchAction.Delete.on(task(done = "2026-10-10T10:00")))
    }

    @Test
    fun r109_a_date_is_taken_back_to_what_each_task_had() {
        assertEquals(Step(Back.Due(null)), BatchAction.Due("2026-10-11").on(task()))
        assertEquals(Step(Back.Due("2026-10-09T09:00")), BatchAction.Due("2026-10-11").on(task(due = "2026-10-09T09:00")))
        assertEquals(Step(Back.Start("2026-10-01")), BatchAction.Start("2026-10-11").on(task(start = "2026-10-01")))
    }

    @Test
    fun r109_a_task_that_already_has_the_value_is_passed_over() {
        assertNull(BatchAction.Due("2026-10-11").on(task(due = "2026-10-11")))
        assertNull(BatchAction.Start("2026-10-11").on(task(start = "2026-10-11")))
        assertNull(BatchAction.SetPriority(Priority.HIGH).on(task(priority = Priority.HIGH)))
        assertNull(BatchAction.Tag("#Home").on(task(tags = listOf("home"))))
        assertNull(BatchAction.MoveTo("work").on(task(listId = "work")))
    }

    @Test
    fun r109_a_priority_and_a_tag_are_taken_back() {
        assertEquals(Step(Back.SetPriority(Priority.LOW)), BatchAction.SetPriority(Priority.HIGH).on(task(priority = Priority.LOW)))
        assertEquals(Step(Back.Untag("home")), BatchAction.Tag("#Home").on(task(tags = listOf("work"))))
    }

    @Test
    fun r109_a_move_is_taken_back_to_the_former_list_or_parent() {
        assertEquals(Step(Back.Place("inbox", null)), BatchAction.MoveTo("work").on(task()))
        // A subtask of a task in the same list still moves: it becomes a task of the list.
        assertEquals(Step(Back.Place("work", "p")), BatchAction.MoveTo("work").on(task(listId = "work", parentId = "p")))
    }

    @Test
    fun r109_nothing_applies_to_a_task_in_the_trash_or_to_a_record() {
        for (action in listOf(BatchAction.Complete, BatchAction.Delete, BatchAction.Due("2026-10-11"), BatchAction.MoveTo("work"))) {
            assertNull(action.on(task(deleted = true)))
            assertNull(action.on(task(isLog = true)))
        }
    }

    @Test
    fun r109_a_task_that_left_the_view_drops_out_of_the_selection() {
        assertEquals(setOf("a", "c"), setOf("a", "b", "c").kept(listOf("c", "a", "d")))
        assertEquals(emptySet<String>(), setOf("a").kept(emptyList()))
    }

    private val order = listOf("a", "b", "c", "d", "e")

    @Test
    fun r109_a_drag_selects_the_rows_from_its_first_to_the_one_under_the_finger() {
        assertEquals(setOf("b", "c", "d"), dragged(emptySet(), order, "b", "d"))
        assertEquals(setOf("b", "c", "d"), dragged(emptySet(), order, "d", "b"))
        assertEquals(setOf("c"), dragged(emptySet(), order, "c", "c"))
    }

    @Test
    fun r109_going_back_gives_up_the_rows_the_drag_added_and_keeps_the_rest() {
        val base = setOf("e")
        assertEquals(setOf("a", "b", "c", "e"), dragged(base, order, "a", "c"))
        assertEquals(setOf("a", "b", "e"), dragged(base, order, "a", "b"))
    }

    @Test
    fun r109_a_drag_over_a_row_that_is_gone_changes_nothing() {
        assertEquals(setOf("e"), dragged(setOf("e"), order, "a", "x"))
    }
}
