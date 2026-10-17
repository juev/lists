package org.evsyukov.lists.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.lists_core.Scope

class ReadForTest {
    private val inbox = UiState(scope = Scope.Inbox)

    @Test
    fun results_read_for_an_older_search_are_not_shown_under_a_newer_one() {
        // "mi" is typed, then "milk": the read for "mi" ends last.
        assertFalse(readFor(inbox.copy(search = "milk"), read = inbox.copy(search = "mi")))
        assertFalse(readFor(inbox, read = inbox.copy(search = "mi")))
    }

    @Test
    fun results_read_for_another_view_are_not_shown() {
        assertFalse(readFor(UiState(scope = Scope.Today), read = inbox))
    }

    @Test
    fun results_read_for_the_view_and_the_search_on_screen_are_shown() {
        assertTrue(readFor(inbox.copy(search = "milk"), read = inbox.copy(search = "milk")))
        assertTrue(readFor(inbox, read = inbox))
    }
}
