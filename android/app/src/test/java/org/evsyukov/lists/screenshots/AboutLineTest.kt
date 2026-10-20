package org.evsyukov.lists.screenshots

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.evsyukov.lists.ui.AboutLine
import org.evsyukov.lists.ui.theme.ListsTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** R160: the line under the settings sections names the version and the author and opens the author's site. */
@RunWith(RobolectricTestRunner::class)
@Config(application = ScreenshotApp::class, sdk = [35], qualifiers = PHONE)
class AboutLineTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun r160_the_line_names_the_version_and_the_author_and_opens_the_site() {
        val opened = mutableListOf<String>()
        val handler = object : UriHandler {
            override fun openUri(uri: String) {
                opened += uri
            }
        }
        compose.setContent {
            CompositionLocalProvider(LocalUriHandler provides handler) { ListsTheme(dark = false, dynamic = false) { AboutLine("0.7.0") } }
        }
        val line = compose.onNodeWithText("Lists 0.7.0 · Denis Evsyukov")
        line.assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
        line.performClick()
        assertEquals(listOf("https://denis.evsyukov.org"), opened)
    }
}
