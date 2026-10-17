package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import uniffi.lists_core.Priority
import uniffi.lists_core.TaskItem

class MarkStateTest {
    private fun task(done: String? = null, wont: Boolean = false, isLog: Boolean = false, undoable: Boolean = false) = TaskItem(
        "a", "inbox", null, null, "a", "", null, null, Priority.NONE, emptyList(), null, null, done,
        wont, false, isLog, false, 0u, 0u, 0u, null, null, undoable,
    )

    @Test
    fun r133_a_record_shows_its_mark_while_its_completion_can_be_undone_and_the_repeat_icon_after() {
        assertEquals(MarkState.Done, task(done = "2026-10-17T10:00", isLog = true, undoable = true).markState())
        assertEquals(MarkState.Wont, task(done = "2026-10-17T10:00", wont = true, isLog = true, undoable = true).markState())
        assertEquals(MarkState.History, task(done = "2026-10-17T10:00", isLog = true).markState())
        assertEquals(MarkState.History, task(done = "2026-10-17T10:00", wont = true, isLog = true).markState())
        assertEquals("an ordinary task keeps its mark", MarkState.Done, task(done = "2026-10-17T10:00").markState())
    }
}
