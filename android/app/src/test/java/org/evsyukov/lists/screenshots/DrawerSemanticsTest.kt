package org.evsyukov.lists.screenshots

import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.evsyukov.lists.LookPrefs
import org.evsyukov.lists.ui.DrawerCatalog
import org.evsyukov.lists.ui.theme.ListsTheme
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.time.LocalDate

/** R158: what a screen reader learns from the heading of a section of the panel of lists. */
@RunWith(RobolectricTestRunner::class)
@Config(application = ScreenshotApp::class, sdk = [35], qualifiers = PHONE)
class DrawerSemanticsTest {
    @get:Rule
    val compose = createComposeRule()

    // The folded sections live in an object of the app: they are put back for the other tests.
    @After
    fun unfold() {
        LookPrefs.setFolded(RuntimeEnvironment.getApplication(), "lists", false)
    }

    @Test
    fun r158_a_heading_is_a_button_that_says_whether_its_section_is_folded() {
        compose.setContent { ListsTheme(dark = false, dynamic = false) { DrawerCatalog(LocalDate.now()) } }
        val heading = compose.onNodeWithText("Lists")
        heading.assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
        heading.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Expanded"))
        heading.performClick()
        compose.onNodeWithText("Lists").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Collapsed"))
        compose.onNodeWithText("Lists").performClick()
        compose.onNodeWithText("Lists").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Expanded"))
    }
}
