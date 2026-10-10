package org.evsyukov.lists

import org.junit.Assert.assertEquals
import org.junit.Test

class TextScaleTest {
    @Test
    fun r100_the_steps_are_those_of_macos() {
        assertEquals(listOf(0.9f, 1f, 1.15f, 1.3f, 1.5f), LookPrefs.textScales)
    }

    @Test
    fun r100_nothing_saved_is_the_default_step() {
        assertEquals(1f, LookPrefs.textScaleFrom(null))
    }

    @Test
    fun r100_a_saved_step_is_kept() {
        for (step in LookPrefs.textScales) assertEquals(step, LookPrefs.textScaleFrom(step))
    }

    @Test
    fun r100_a_saved_value_that_is_not_a_step_is_the_default() {
        assertEquals(1f, LookPrefs.textScaleFrom(2f))
        assertEquals(1f, LookPrefs.textScaleFrom(0f))
    }
}
