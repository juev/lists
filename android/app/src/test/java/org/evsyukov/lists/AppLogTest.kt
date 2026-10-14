package org.evsyukov.lists

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import uniffi.lists_core.AppException
import uniffi.lists_core.LogLevel
import java.io.FileNotFoundException

class AppLogTest {
    @Test
    fun r102_the_text_of_the_core_is_the_cause() {
        assertEquals("not found", logged(AppException.NotFound("task 1")))
        assertEquals("invalid: no such list", logged(AppException.Invalid("no such list")))
        assertEquals("storage: disk full", logged(AppException.Storage("disk full")))
    }

    @Test
    fun r102_an_error_about_a_file_does_not_name_it() {
        val cause = logged(FileNotFoundException("/data/user/0/org.evsyukov.lists/cache/incoming/1/Report.pdf (No such file)"))
        assertEquals("FileNotFoundException", cause)
        assertFalse(cause.contains("Report"))
    }

    @Test
    fun r102_inexact_alarms_are_one_error_line() {
        assertEquals(LogLevel.ERROR, Reminders.wayNote(wasInexact = false, inexact = true)?.first)
        assertNull(Reminders.wayNote(wasInexact = true, inexact = true))
    }

    @Test
    fun r102_exact_alarms_again_are_an_info_line() {
        assertEquals(LogLevel.INFO, Reminders.wayNote(wasInexact = true, inexact = false)?.first)
        assertNull(Reminders.wayNote(wasInexact = false, inexact = false))
    }
}
