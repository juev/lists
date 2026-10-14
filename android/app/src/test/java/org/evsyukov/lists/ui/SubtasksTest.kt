package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.lists_core.Priority
import uniffi.lists_core.TaskItem

class SubtasksTest {
    private fun task(
        parentId: String? = null,
        done: String? = null,
        wont: Boolean = false,
        deleted: Boolean = false,
        isLog: Boolean = false,
        isProject: Boolean = false,
        subtasksTotal: UInt = 0u,
    ) = TaskItem(
        "a", "inbox", parentId, null, "a", "", null, null, Priority.NONE, emptyList(), null, null, done,
        wont, deleted, isLog, isProject, subtasksTotal, 0u, 0u, null, null,
    )

    @Test
    fun r38_the_menu_of_an_open_subtask_holds_rename_complete_wont_do_and_delete() {
        assertEquals(
            listOf(SubtaskAction.Rename, SubtaskAction.Complete, SubtaskAction.WontDo, SubtaskAction.Delete),
            subtaskMenu(task(parentId = "p")),
        )
    }

    @Test
    fun r38_the_menu_of_a_closed_subtask_reopens_it_and_does_not_close_it_again() {
        val closed = listOf(SubtaskAction.Rename, SubtaskAction.Reopen, SubtaskAction.Delete)
        assertEquals(closed, subtaskMenu(task(parentId = "p", done = "2026-10-11T10:00")))
        assertEquals(closed, subtaskMenu(task(parentId = "p", done = "2026-10-11T10:00", wont = true)))
    }

    @Test
    fun r38_a_subtask_in_the_trash_is_only_restored_and_a_record_only_deleted() {
        assertEquals(listOf(SubtaskAction.Restore), subtaskMenu(task(parentId = "p", deleted = true)))
        assertEquals(listOf(SubtaskAction.DeleteRecord), subtaskMenu(task(parentId = "p", isLog = true)))
    }

    @Test
    fun r32_a_project_with_tasks_is_not_offered_to_turn_back_into_a_task() {
        assertFalse(task(isProject = true, subtasksTotal = 1u).offersProjectSwitch())
    }

    @Test
    fun r32_an_empty_project_and_a_task_of_the_top_level_are_offered_the_switch() {
        assertTrue(task(isProject = true).offersProjectSwitch())
        assertTrue(task().offersProjectSwitch())
        // A task with subtasks becomes a project: they become its tasks.
        assertTrue(task(subtasksTotal = 2u).offersProjectSwitch())
    }

    @Test
    fun r32_a_task_of_a_project_is_not_offered_the_switch() {
        assertFalse(task(parentId = "p").offersProjectSwitch())
    }

    @Test
    fun r38_a_changed_title_is_saved_without_the_spaces_around_it() {
        assertEquals("bread", renamed("milk", "  bread "))
    }

    @Test
    fun r38_an_empty_title_and_one_that_did_not_change_are_not_saved() {
        assertNull(renamed("milk", ""))
        assertNull(renamed("milk", "   "))
        assertNull(renamed("milk", "milk"))
        assertNull(renamed("milk", " milk "))
    }

    @Test
    fun r38_pasted_lines_become_one_title() {
        assertEquals("milk and bread", renamed("milk", "milk\n and bread\n"))
    }
}
