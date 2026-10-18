package org.evsyukov.lists.screenshots

import androidx.compose.runtime.Composable
import com.github.takahirom.roborazzi.captureRoboImage
import org.evsyukov.lists.ui.CatalogPage
import org.evsyukov.lists.ui.DrawerCatalog
import org.evsyukov.lists.ui.FieldsCatalog
import org.evsyukov.lists.ui.MarksCatalog
import org.evsyukov.lists.ui.TaskRowsCatalog
import org.evsyukov.lists.ui.ViewTintsCatalog
import org.evsyukov.lists.ui.theme.ListsTheme
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import uniffi.lists_core.Scope
import java.time.LocalDate

/**
 * #369: the building blocks of the screens in the light and the dark look, with the fixed palette.
 * `make android` compares them with src/test/screenshots; `make android-screenshots` records them.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = ScreenshotApp::class, sdk = [35], qualifiers = PHONE)
class CatalogScreenshotTest {
    private fun shot(name: String, content: @Composable () -> Unit) = captureRoboImage("src/test/screenshots/$name.png", content = content)

    @Test
    fun marks() {
        shot("marks_light") { CatalogPage(dark = false, title = "Marks") { MarksCatalog() } }
        shot("marks_dark") { CatalogPage(dark = true, title = "Marks") { MarksCatalog() } }
    }

    @Test
    fun fields() {
        shot("fields_light") { CatalogPage(dark = false, title = "Fields") { FieldsCatalog() } }
        shot("fields_dark") { CatalogPage(dark = true, title = "Fields") { FieldsCatalog() } }
    }

    @Test
    fun view_tints() {
        shot("view_tints_light") { CatalogPage(dark = false, title = "View tints") { ViewTintsCatalog() } }
        shot("view_tints_dark") { CatalogPage(dark = true, title = "View tints") { ViewTintsCatalog() } }
    }

    @Test
    fun task_rows() {
        val today = LocalDate.now()
        shot("rows_today_light") { CatalogPage(dark = false, title = "Today") { TaskRowsCatalog(today, Scope.Today) } }
        shot("rows_today_dark") { CatalogPage(dark = true, title = "Today") { TaskRowsCatalog(today, Scope.Today) } }
        shot("rows_list_light") { CatalogPage(dark = false, title = "Работа") { TaskRowsCatalog(today, Scope.List("work")) } }
    }

    @Test
    @Config(fontScale = LARGE_TEXT)
    fun task_rows_with_large_text() {
        shot("rows_today_large_text") { CatalogPage(dark = false, title = "Today") { TaskRowsCatalog(LocalDate.now(), Scope.Today) } }
    }

    @Test
    fun drawer() {
        shot("drawer_light") { ListsTheme(dark = false, dynamic = false) { DrawerCatalog(LocalDate.now()) } }
        shot("drawer_dark") { ListsTheme(dark = true, dynamic = false) { DrawerCatalog(LocalDate.now()) } }
    }

    @Test
    @Config(fontScale = LARGE_TEXT)
    fun fields_with_large_text() {
        shot("fields_large_text") { CatalogPage(dark = false, title = "Fields") { FieldsCatalog() } }
    }
}

/** A phone of the size of the screenshots in docs/screenshots: 1080 × 2400 at 420 dpi. */
const val PHONE = "w411dp-h914dp-xxhdpi"

/** The largest text size of the system settings. */
const val LARGE_TEXT = 2.0f
