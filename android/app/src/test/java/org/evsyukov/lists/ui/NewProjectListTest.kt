package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import uniffi.lists_core.Priority
import uniffi.lists_core.Scope
import uniffi.lists_core.TaskItem

class NewProjectListTest {
    private fun project(id: String, listId: String) = TaskItem(
        id, listId, null, null, id, "", null, null, Priority.NONE, emptyList(), null, null, null,
        false, false, false, true, 0u, 0u, 0u, null, null,
    )

    private val state = UiState(projects = listOf(project("trip", "work")))

    @Test
    fun r127_a_project_goes_to_the_list_on_screen() {
        assertEquals("home", state.copy(scope = Scope.List("home")).newProjectListId())
        assertEquals("inbox", state.copy(scope = Scope.Inbox).newProjectListId())
    }

    @Test
    fun r127_in_the_view_of_a_project_a_new_one_goes_to_the_list_of_that_project() {
        assertEquals("work", state.copy(scope = Scope.Project("trip")).newProjectListId())
    }
}
