package org.evsyukov.lists.screenshots

import androidx.compose.ui.test.junit4.createComposeRule
import org.evsyukov.lists.every
import org.evsyukov.lists.summary
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import uniffi.lists_core.Freq

@RunWith(RobolectricTestRunner::class)
@Config(application = ScreenshotApp::class, sdk = [35], qualifiers = "zh-rCN")
class ChineseRepeatTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun monthlyWeekdayUsesChineseWordOrder() {
        var actual = ""
        compose.setContent { actual = every(Freq.MONTHLY).copy(nth = 2, nthWeekday = 3u).summary() }
        compose.runOnIdle { assertEquals("每月第2个周三", actual) }
    }

    @Test
    fun weeklyIntervalUsesChineseSeparator() {
        var actual = ""
        compose.setContent { actual = every(Freq.WEEKLY, 2u, listOf(1u, 3u)).summary() }
        compose.runOnIdle { assertEquals("每 2 周：周一、周三", actual) }
    }
}
