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
}
