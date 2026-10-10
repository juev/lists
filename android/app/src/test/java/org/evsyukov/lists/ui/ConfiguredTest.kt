package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import uniffi.lists_core.DueWindow
import uniffi.lists_core.FilterSpec
import uniffi.lists_core.FilterStatus
import uniffi.lists_core.Priority
import uniffi.lists_core.SavedFilter
import uniffi.lists_core.Scope
import uniffi.lists_core.SortMode
import uniffi.lists_core.TaskList

class ConfiguredTest {
    private fun list(id: String, name: String) = TaskList(id, name, "", "", SortMode.MANUAL, false, Priority.NONE, false, false, 0u)

    private val inbox = list("inbox", "")
    private val work = list("work", "Work")
    private val home = list("home", "Home")
    private val week = SavedFilter("week", "Week", FilterSpec(DueWindow.Any, emptyList(), emptyList(), Priority.NONE, FilterStatus.OPEN, ""), 0u)
    private val state = UiState(lists = listOf(inbox, work, home), filters = listOf(week))

    @Test
    fun r105_an_open_list_offers_its_own_settings() {
        assertEquals(Configured.OfList(work), state.copy(scope = Scope.List("work")).configured)
        assertEquals(Configured.OfList(home), state.copy(scope = Scope.List("home")).configured)
    }

    @Test
    fun r105_the_inbox_offers_the_settings_of_the_inbox() {
        assertEquals(Configured.OfList(inbox), state.copy(scope = Scope.Inbox).configured)
    }

    @Test
    fun r105_an_open_filter_offers_its_own_settings() {
        assertEquals(Configured.OfFilter(week), state.copy(scope = Scope.Filter("week")).configured)
    }

    @Test
    fun r105_views_without_settings_offer_nothing() {
        for (scope in listOf(Scope.Today, Scope.Upcoming, Scope.All, Scope.Completed, Scope.WontDo, Scope.Trash, Scope.Tag("work"), Scope.Project("work"))) {
            assertNull("$scope", state.copy(scope = scope).configured)
        }
    }

    @Test
    fun r105_a_list_or_a_filter_that_is_gone_offers_nothing() {
        assertNull(state.copy(scope = Scope.List("gone")).configured)
        assertNull(state.copy(scope = Scope.Filter("gone")).configured)
        assertNull(UiState(scope = Scope.Inbox).configured)
    }

    @Test
    fun r105_nothing_is_offered_while_the_search_is_open() {
        assertNull(state.copy(scope = Scope.List("work"), search = "").configured)
        assertNull(state.copy(scope = Scope.List("work"), search = "report").configured)
    }
}
