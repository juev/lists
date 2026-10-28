package org.evsyukov.lists

import android.content.Intent
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.test.core.app.ApplicationProvider
import org.evsyukov.lists.screenshots.ScreenshotApp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.xmlpull.v1.XmlPullParser

/** R163: Lists in the Direct Share row of the share sheet, and the "New task" item of the icon menu. */
@RunWith(RobolectricTestRunner::class)
@Config(application = ScreenshotApp::class, sdk = [35])
class DirectShareTest {
    private val context = ApplicationProvider.getApplicationContext<ListsApp>()

    @Test
    fun r163_the_published_shortcut_is_a_share_target_that_opens_quick_entry() {
        DirectShare.publish(context)

        val shortcuts = ShortcutManagerCompat.getDynamicShortcuts(context)
        assertEquals(listOf(DirectShare.ID), shortcuts.map { it.id })
        val shortcut = shortcuts.single()
        assertEquals(setOf(DirectShare.CATEGORY), shortcut.categories)
        assertEquals("New task", shortcut.shortLabel)
        assertEquals(QuickAddActivity::class.java.name, shortcut.intent.component?.className)
    }

    @Test
    fun r163_publishing_again_keeps_one_shortcut() {
        DirectShare.publish(context)
        DirectShare.publish(context)

        assertEquals(listOf(DirectShare.ID), ShortcutManagerCompat.getDynamicShortcuts(context).map { it.id })
    }

    @Test
    fun r163_the_share_target_takes_what_share_takes_and_nothing_else_is_declared() {
        val targets = mutableListOf<String>()
        val categories = mutableListOf<String>()
        val types = mutableListOf<String>()
        val shortcuts = mutableListOf<String>()
        context.resources.getXml(R.xml.shortcuts).use { xml ->
            while (xml.next() != XmlPullParser.END_DOCUMENT) {
                if (xml.eventType != XmlPullParser.START_TAG) continue
                val value = { name: String -> xml.getAttributeValue(ANDROID, name) }
                when (xml.name) {
                    "share-target" -> targets += value("targetClass")
                    "category" -> categories += value("name")
                    "data" -> types += value("mimeType")
                    "shortcut" -> shortcuts += value("shortcutId")
                }
            }
        }

        assertEquals(listOf(QuickAddActivity::class.java.name), targets)
        assertEquals(listOf(DirectShare.CATEGORY), categories)
        // A static shortcut would stand next to the dynamic one as a second "New task" in the icon menu.
        assertEquals(emptyList<String>(), shortcuts)
        assertEquals(listOf("text/plain", "image/*", "application/*"), types)
        for (type in types) {
            val handlers = context.packageManager.queryIntentActivities(Intent(Intent.ACTION_SEND).setType(type), 0)
            assertTrue(type, handlers.any { it.activityInfo.name == QuickAddActivity::class.java.name })
        }
    }

    private companion object {
        const val ANDROID = "http://schemas.android.com/apk/res/android"
    }
}
