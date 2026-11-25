package org.evsyukov.lists

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.view.ContextThemeWrapper
import androidx.test.core.app.ApplicationProvider
import org.evsyukov.lists.screenshots.ScreenshotApp
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** R61: the platform window shown before the first Compose frame follows the system appearance. */
@RunWith(RobolectricTestRunner::class)
@Config(application = ScreenshotApp::class, sdk = [26, 35])
class LaunchThemeTest {
    private fun windowBackground(): Int {
        val context = ContextThemeWrapper(ApplicationProvider.getApplicationContext<Context>(), R.style.Theme_Lists)
        val attributes = context.theme.obtainStyledAttributes(intArrayOf(android.R.attr.windowBackground))
        val drawable = attributes.getDrawable(0)
        attributes.recycle()
        assertTrue("the window background is a colour", drawable is ColorDrawable)
        return (drawable as ColorDrawable).color
    }

    @Test
    @Config(qualifiers = "night")
    fun r61_starting_window_is_dark_in_the_dark_system() {
        val color = windowBackground()
        val description = Integer.toHexString(color)
        assertTrue("the night window is light: #$description", Color.red(color) < 128 && Color.green(color) < 128 && Color.blue(color) < 128)
    }

    @Test
    @Config(qualifiers = "notnight")
    fun r61_starting_window_stays_light_in_the_light_system() {
        val color = windowBackground()
        val description = Integer.toHexString(color)
        assertTrue("the day window is dark: #$description", Color.red(color) >= 128 && Color.green(color) >= 128 && Color.blue(color) >= 128)
    }
}
