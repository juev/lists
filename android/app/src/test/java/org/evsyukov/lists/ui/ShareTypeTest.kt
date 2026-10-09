package org.evsyukov.lists.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** R91: the type a share sheet is asked for when it carries every file of a task. */
class ShareTypeTest {
    @Test
    fun r91_files_of_one_type_are_shared_as_that_type() {
        assertEquals("image/png", shareType(listOf("image/png", "image/png")))
    }

    @Test
    fun r91_files_of_one_kind_are_shared_as_that_kind() {
        assertEquals("image/*", shareType(listOf("image/png", "image/jpeg")))
    }

    @Test
    fun r91_files_of_different_kinds_are_shared_as_anything() {
        assertEquals("*/*", shareType(listOf("image/png", "application/pdf", "text/plain")))
        assertEquals("*/*", shareType(emptyList()))
    }
}
