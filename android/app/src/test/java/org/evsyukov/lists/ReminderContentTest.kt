package org.evsyukov.lists

import org.junit.Assert.assertEquals
import org.junit.Test
import uniffi.lists_core.NotificationKind
import uniffi.lists_core.PlannedNotification
import java.time.LocalDate

class ReminderContentTest {
    private fun planned(kind: NotificationKind, due: String?) =
        PlannedNotification(key = "task:1", kind = kind, at = "2026-10-16T09:00", taskId = "1", title = "Pay rent", due = due, count = 0u)

    @Test
    fun r36_an_alarm_carries_the_due_date_itself_not_a_text_written_at_planning() {
        assertEquals(Triple("Pay rent", "", "2026-10-16"), Reminders.content(planned(NotificationKind.DUE, "2026-10-16")))
        assertEquals(Triple("Pay rent", "", "2026-10-16T10:00"), Reminders.content(planned(NotificationKind.REMINDER, "2026-10-16T10:00")))
        assertEquals(Triple("Pay rent", "", null), Reminders.content(planned(NotificationKind.REMINDER, null)))
    }

    @Test
    fun r36_the_due_day_is_counted_from_the_day_the_notification_appears() {
        // Planned the day before, shown on the due day: the day is today, not tomorrow (#280).
        assertEquals(1L, daysAhead("2026-10-16", LocalDate.parse("2026-10-15")))
        assertEquals(0L, daysAhead("2026-10-16", LocalDate.parse("2026-10-16")))
        assertEquals(0L, daysAhead("2026-10-16T10:00", LocalDate.parse("2026-10-16")))
        assertEquals(-1L, daysAhead("2026-10-16", LocalDate.parse("2026-10-17")))
    }
}
