package org.evsyukov.lists

import org.junit.Assert.assertEquals
import org.junit.Test

class TodayNoticeTest {
    @Test
    fun r104_no_tasks_list_nothing() {
        assertEquals(emptyList<String>() to 0, TodayNotice.listed(emptyList()))
    }

    @Test
    fun r104_up_to_five_titles_are_all_listed_in_their_order() {
        val titles = listOf("a", "b", "c", "d", "e")
        assertEquals(titles to 0, TodayNotice.listed(titles))
    }

    @Test
    fun r104_past_five_the_rest_are_counted() {
        val titles = listOf("a", "b", "c", "d", "e", "f", "g")
        assertEquals(listOf("a", "b", "c", "d", "e") to 2, TodayNotice.listed(titles))
    }

    @Test
    fun r104_the_heading_follows_what_the_icon_counts() {
        assertEquals(TodayNotice.Heading.TODAY, TodayNotice.heading("today", open = 3, overdue = 1))
        assertEquals(TodayNotice.Heading.TODAY, TodayNotice.heading("none", open = 3, overdue = 1))
        assertEquals(TodayNotice.Heading.OVERDUE, TodayNotice.heading("overdue", open = 3, overdue = 1))
    }

    @Test
    fun r104_without_overdue_tasks_the_heading_is_that_of_today() {
        assertEquals(TodayNotice.Heading.TODAY, TodayNotice.heading("overdue", open = 3, overdue = 0))
    }

    @Test
    fun r104_nothing_for_today_is_said_whatever_is_counted() {
        for (choice in IconCount.choices) assertEquals(TodayNotice.Heading.EMPTY, TodayNotice.heading(choice, open = 0, overdue = 0))
    }
}
