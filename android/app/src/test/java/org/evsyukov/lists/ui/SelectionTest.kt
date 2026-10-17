package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.lists_core.Freq
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
        isProject: Boolean = false,
        subtasksTotal: UInt = 0u,
    ) = TaskItem(
        id, listId, parentId, null, id, "", start, due, priority, tags, repeat, null, done,
        false, deleted, isLog, isProject, subtasksTotal, 0u, 0u, due, start,
    )

    @Test
    fun r109_the_bar_has_one_action_when_only_the_trash_or_only_records_are_selected() {
        assertEquals(SelectionActions.Usual, selectionActions(emptyList()))
        assertEquals(SelectionActions.Usual, selectionActions(listOf(task(), task(done = "2026-10-10T10:00"))))
        assertEquals(SelectionActions.Restore, selectionActions(listOf(task(deleted = true), task(deleted = true))))
        assertEquals(SelectionActions.DeleteRecords, selectionActions(listOf(task(isLog = true))))
        assertEquals(SelectionActions.Usual, selectionActions(listOf(task(isLog = true), task(done = "2026-10-10T10:00"))))
    }

    @Test
    fun r109_a_task_in_the_trash_is_only_restored() {
        assertTrue(BatchAction.Restore.appliesTo(task(deleted = true)))
        assertFalse(BatchAction.Restore.appliesTo(task()))
        assertFalse(BatchAction.Restore.appliesTo(task(isLog = true)))
    }

    @Test
    fun r109_a_record_is_deleted() {
        assertTrue(BatchAction.Delete.appliesTo(task(isLog = true)))
    }

    @Test
    fun r109_an_open_task_is_completed() {
        assertTrue(BatchAction.Complete.appliesTo(task()))
        assertTrue(BatchAction.WontDo.appliesTo(task()))
    }

    @Test
    fun r128_a_repeating_task_is_completed_as_well() {
        val daily = Repeat(Freq.DAILY, 1u, emptyList(), null, null, null, false, null, null)
        assertTrue(BatchAction.Complete.appliesTo(task(repeat = daily)))
        assertTrue(BatchAction.WontDo.appliesTo(task(repeat = daily)))
    }

    @Test
    fun r109_a_closed_task_is_passed_over_when_completing() {
        assertFalse(BatchAction.Complete.appliesTo(task(done = "2026-10-10T10:00")))
        assertFalse(BatchAction.WontDo.appliesTo(task(done = "2026-10-10T10:00")))
    }

    @Test
    fun r109_a_closed_task_is_deleted_as_well() {
        assertTrue(BatchAction.Delete.appliesTo(task()))
        assertTrue(BatchAction.Delete.appliesTo(task(done = "2026-10-10T10:00")))
    }

    @Test
    fun r109_a_date_goes_to_a_task_that_has_another() {
        assertTrue(BatchAction.Due("2026-10-11").appliesTo(task()))
        assertTrue(BatchAction.Due("2026-10-11").appliesTo(task(due = "2026-10-09T09:00")))
        assertTrue(BatchAction.Start("2026-10-11").appliesTo(task(start = "2026-10-01")))
    }

    @Test
    fun r109_a_task_that_already_has_the_value_is_passed_over() {
        assertFalse(BatchAction.Due("2026-10-11").appliesTo(task(due = "2026-10-11")))
        assertFalse(BatchAction.Start("2026-10-11").appliesTo(task(start = "2026-10-11")))
        assertFalse(BatchAction.SetPriority(Priority.HIGH).appliesTo(task(priority = Priority.HIGH)))
        assertFalse(BatchAction.Tag("#Home").appliesTo(task(tags = listOf("home"))))
        assertFalse(BatchAction.MoveTo("work").appliesTo(task(listId = "work")))
    }

    @Test
    fun r109_a_priority_and_a_tag_go_to_a_task_without_them() {
        assertTrue(BatchAction.SetPriority(Priority.HIGH).appliesTo(task(priority = Priority.LOW)))
        assertTrue(BatchAction.Tag("#Home").appliesTo(task(tags = listOf("work"))))
    }

    @Test
    fun r109_a_task_moves_from_another_list_or_from_a_project() {
        assertTrue(BatchAction.MoveTo("work").appliesTo(task()))
        // A subtask of a task in the same list still moves: it becomes a task of the list.
        assertTrue(BatchAction.MoveTo("work").appliesTo(task(listId = "work", parentId = "p")))
    }

    @Test
    fun r129_a_move_into_a_project_passes_over_what_a_drop_onto_it_does() {
        val into = BatchAction.MoveToProject("p")
        assertTrue(into.appliesTo(task()))
        // From another project: back to that one.
        assertTrue(into.appliesTo(task(listId = "work", parentId = "q")))
        assertFalse("the project itself", into.appliesTo(task(id = "p", isProject = true)))
        assertFalse("another project", into.appliesTo(task(isProject = true)))
        assertFalse("a task with subtasks", into.appliesTo(task(subtasksTotal = 2u)))
        assertFalse("a task already in the project", into.appliesTo(task(parentId = "p")))
        assertFalse(into.appliesTo(task(deleted = true)))
        assertFalse(task(subtasksTotal = 1u).goesInto("p"))
        assertTrue(task(parentId = "q").goesInto("p"))
        assertEquals(BatchAction.MoveTo("work").done(), into.done())
    }

    @Test
    fun r109_the_other_actions_pass_over_a_task_in_the_trash_and_a_record() {
        for (action in listOf(BatchAction.Complete, BatchAction.Due("2026-10-11"), BatchAction.MoveTo("work"))) {
            assertFalse(action.appliesTo(task(deleted = true)))
            assertFalse(action.appliesTo(task(isLog = true)))
        }
        assertFalse(BatchAction.Delete.appliesTo(task(deleted = true)))
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
