package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.lists_core.Freq
import uniffi.lists_core.Priority
import uniffi.lists_core.Repeat

class NewTaskEntryTest {
    private fun content(
        text: String = "",
        note: String = "",
        start: String? = null,
        due: String? = null,
        repeats: Boolean = false,
        priority: Priority? = null,
        files: Int = 0,
    ) = hasContent(text, note, start, due, repeats, priority, files)

    @Test
    fun r97_an_untouched_card_holds_nothing() {
        assertFalse(content())
        assertFalse(content(text = "  ", note = "\n"))
        // The list and the size are not an entry: a card with only those closes without the bar.
        assertFalse(NewTaskEntry(listId = "work").apply { expanded = true }.hasContent)
    }

    @Test
    fun r97_any_field_the_person_filled_is_content() {
        assertTrue(content(text = "milk"))
        assertTrue(content(note = "two litres"))
        assertTrue(content(start = "2026-10-10"))
        assertTrue(content(due = "2026-10-10T10:00"))
        assertTrue(content(repeats = true))
        assertTrue(content(priority = Priority.HIGH))
        assertTrue(content(priority = Priority.NONE))
        assertTrue(content(files = 1))
    }

    @Test
    fun r97_a_card_emptied_by_saving_holds_nothing() {
        val entry = NewTaskEntry(title = "milk").apply { due = "2026-10-10" }
        assertTrue(entry.hasContent)
        entry.text = ""
        entry.due = null
        assertFalse(entry.hasContent)
    }

    @Test
    fun r63_everything_entered_comes_back_from_the_saved_state() {
        val rule = Repeat(freq = Freq.WEEKLY, interval = 2u, weekdays = listOf(1u, 3u), monthday = null, nth = null, nthWeekday = null, fromDone = true, count = 5u, until = "2027-01-01")
        val entry = NewTaskEntry("milk", "two litres", "work").apply {
            taken = "two litres"
            start = "2026-10-09"
            due = "2026-10-10T10:00"
            dueRemoved = true
            repeat = rule
            priority = Priority.MEDIUM
            expanded = true
        }
        val back = NewTaskEntry.fromSaved(entry.toSaved())
        assertEquals("milk", back.text)
        assertEquals("two litres", back.note)
        assertEquals("two litres", back.taken)
        assertEquals("2026-10-09", back.start)
        assertEquals("2026-10-10T10:00", back.due)
        assertTrue(back.dueRemoved)
        assertEquals(rule, back.repeat)
        assertEquals(Priority.MEDIUM, back.priority)
        assertEquals("work", back.listId)
        assertTrue(back.expanded)
    }

    @Test
    fun r63_an_empty_card_comes_back_empty() {
        val back = NewTaskEntry.fromSaved(NewTaskEntry().toSaved())
        assertEquals("", back.text)
        assertNull(back.repeat)
        assertNull(back.priority)
        assertNull(back.listId)
        assertFalse(back.hasContent)
    }
}
