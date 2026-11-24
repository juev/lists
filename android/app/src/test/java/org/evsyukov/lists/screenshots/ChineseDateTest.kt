package org.evsyukov.lists.screenshots

import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import org.evsyukov.lists.dateLabel
import org.evsyukov.lists.dayHeading
import org.evsyukov.lists.monthTitle
import org.evsyukov.lists.ui.MomentDialog
import org.evsyukov.lists.ui.theme.ListsTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.LocalDate
import java.time.YearMonth

@RunWith(RobolectricTestRunner::class)
@Config(application = ScreenshotApp::class, sdk = [35], qualifiers = "zh-rCN")
class ChineseDateTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun shortDatePutsMonthAndDayBeforeWeekday() {
        val now = LocalDate.now()
        val day = listOf(now.plusDays(3), now.minusDays(3)).first { it.year == now.year }
        val weekday = listOf("周一", "周二", "周三", "周四", "周五", "周六", "周日")[day.dayOfWeek.value - 1]
        assertEquals("${day.monthValue}月${day.dayOfMonth}日 $weekday", dateLabel(day.toString()))
    }

    @Test
    fun longDatePutsMonthAndDayBeforeWeekday() {
        assertEquals("10月9日 星期一", dayHeading("2000-10-09"))
    }

    @Test
    fun yearComesFirstAndTimeUsesNoAsciiComma() {
        assertEquals("2000年10月9日 18:30", dateLabel("2000-10-09T18:30"))
    }

    @Test
    fun monthTitlePutsYearFirst() {
        compose.setContent {
            ListsTheme(dark = false, dynamic = false) {
                MomentDialog(title = "Due", value = "2000-10-09", onPick = {}, onDismiss = {})
            }
        }
        compose.onNodeWithText("2000年10月").assert(SemanticsMatcher("month title is present") { true })
    }

    @Test
    @Config(qualifiers = "en")
    fun englishDatesKeepTheirOrderAndPunctuation() {
        assertEquals(
            listOf("Monday, 9 October", "9 Oct 2000, 18:30", "October 2000"),
            listOf(dayHeading("2000-10-09"), dateLabel("2000-10-09T18:30"), monthTitle(YearMonth.of(2000, 10))),
        )
    }

    @Test
    @Config(qualifiers = "ru")
    fun russianDatesKeepTheirOrderAndPunctuation() {
        assertEquals(
            listOf("Понедельник, 9 октября", "9 окт. 2000, 18:30", "Октябрь 2000"),
            listOf(dayHeading("2000-10-09"), dateLabel("2000-10-09T18:30"), monthTitle(YearMonth.of(2000, 10))),
        )
    }
}
