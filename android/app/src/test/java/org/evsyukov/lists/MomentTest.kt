package org.evsyukov.lists

import org.evsyukov.lists.ui.initialMoment
import org.evsyukov.lists.ui.monthGrid
import org.evsyukov.lists.ui.weekdaysFrom
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.LocalTime
import java.time.YearMonth

class MomentTest {
    private val today = LocalDate.of(2026, 10, 10)
    private val day = LocalDate.of(2026, 10, 20)

    @Test
    fun r110_a_chosen_day_with_a_time_is_one_moment() {
        assertEquals("2026-10-20T18:30", momentString(day, 18, 30))
        assertEquals("2026-10-20", momentString(day, null, null))
    }

    @Test
    fun r110_the_card_opens_on_the_day_and_the_time_of_the_task() {
        assertEquals(day to LocalTime.of(18, 30), initialMoment("2026-10-20T18:30", timeRequired = false, today = today))
        assertEquals(day to null, initialMoment("2026-10-20", timeRequired = false, today = today))
    }

    @Test
    fun r110_without_a_date_the_card_opens_on_today_without_a_time() {
        assertEquals(today to null, initialMoment(null, timeRequired = false, today = today))
    }

    @Test
    fun r110_a_reminder_always_has_a_time() {
        assertEquals(today to LocalTime.of(9, 0), initialMoment(null, timeRequired = true, today = today))
        assertEquals(day to LocalTime.of(9, 0), initialMoment("2026-10-20", timeRequired = true, today = today))
        assertEquals(day to LocalTime.of(7, 5), initialMoment("2026-10-20T07:05", timeRequired = true, today = today))
    }

    @Test
    fun r110_the_grid_starts_the_week_on_the_first_day_of_the_language() {
        // 1 October 2026 is a Thursday.
        val monday = monthGrid(YearMonth.of(2026, 10), DayOfWeek.MONDAY)
        assertEquals(listOf(null, null, null, 1, 2, 3, 4), monday.first().map { it?.dayOfMonth })
        assertEquals(listOf(26, 27, 28, 29, 30, 31, null), monday.last().map { it?.dayOfMonth })
        assertEquals(5, monday.size)
        val sunday = monthGrid(YearMonth.of(2026, 10), DayOfWeek.SUNDAY)
        assertEquals(listOf(null, null, null, null, 1, 2, 3), sunday.first().map { it?.dayOfMonth })
        assertEquals(listOf(25, 26, 27, 28, 29, 30, 31), sunday.last().map { it?.dayOfMonth })
    }

    @Test
    fun r110_the_grid_holds_every_day_of_the_month_once_in_rows_of_seven() {
        for (month in listOf(YearMonth.of(2026, 2), YearMonth.of(2028, 2), YearMonth.of(2026, 3), YearMonth.of(2026, 8))) {
            for (first in listOf(DayOfWeek.MONDAY, DayOfWeek.SUNDAY, DayOfWeek.SATURDAY)) {
                val grid = monthGrid(month, first)
                assertEquals((1..month.lengthOfMonth()).map(month::atDay), grid.flatten().filterNotNull())
                grid.forEach { week -> assertEquals(7, week.size) }
                // Each day stands under its day of the week.
                grid.forEach { week -> week.forEachIndexed { i, date -> if (date != null) assertEquals(weekdaysFrom(first)[i], date.dayOfWeek) } }
            }
        }
    }

    @Test
    fun r110_a_month_that_begins_on_the_last_day_of_the_week_takes_six_rows() {
        // 1 March 2026 is a Sunday.
        val grid = monthGrid(YearMonth.of(2026, 3), DayOfWeek.MONDAY)
        assertEquals(6, grid.size)
        assertEquals(listOf(null, null, null, null, null, null, 1), grid.first().map { it?.dayOfMonth })
    }
}
