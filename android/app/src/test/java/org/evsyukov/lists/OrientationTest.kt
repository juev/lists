package org.evsyukov.lists

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Test
import org.w3c.dom.Element

/** R77: which windows the manifest holds in portrait. */
class OrientationTest {
    private fun orientation(activity: String): String {
        val manifest = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File("src/main/AndroidManifest.xml")).documentElement
        val nodes = manifest.getElementsByTagName("activity")
        return (0 until nodes.length).map { nodes.item(it) as Element }
            .single { it.getAttribute("android:name") == activity }
            .getAttribute("android:screenOrientation")
    }

    @Test
    fun r77_main_window_is_held_in_portrait() {
        assertEquals("portrait", orientation(".MainActivity"))
    }

    @Test
    fun r77_quick_entry_window_follows_the_app_under_it() {
        // It is translucent and opens over another app, which may stand in landscape.
        assertEquals("", orientation(".QuickAddActivity"))
    }
}
