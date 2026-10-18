package org.evsyukov.lists.ui.theme

import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp

/*
 * The measures of the Android UI (#369). A screen takes its spacing, sizes and corners from here
 * instead of writing numbers of its own; docs/android-design.md says which one goes where.
 */

/** Spacing between and inside elements, from a hairline gap to the margin of a screen. */
object Space {
    /** Between an icon and the text it marks. */
    val xxs = 3.dp

    /** Inside small elements: the padding of a row, the gap of the chips of a weekday. */
    val xs = 4.dp

    /** Between chips and pills in a row. */
    val s = 6.dp

    /** Between a field and its neighbour; the vertical padding of the panel of lists. */
    val m = 8.dp

    /** Between the icon and the text inside a chip. */
    val chipGap = 5.dp

    /** The side padding inside a chip; the gap after the bar of a priority. */
    val chipInset = 10.dp

    /** Between an icon and its label in a row; the horizontal padding of the panel. */
    val l = 12.dp

    /** The margin of a screen and of a row of a list. */
    val xl = 16.dp

    /** Above the heading of a group of rows. */
    val xxl = 20.dp

    /** The end padding of a row of the panel of lists. */
    val xxxl = 24.dp
}

/** Sizes of the elements that recur on every screen. */
object Sizes {
    /** The completion mark of a row (R95) and the icon of a chip. */
    val mark = 16.dp

    /** The tick or cross inside the mark. */
    val markGlyph = 12.dp

    /** The width of the stroke of a mark and of the circle of a project. */
    val stroke = 1.5.dp

    /** The bar of a priority (R72): its width, and its height in a row of one line and of two. */
    val priorityBar = 3.dp
    val priorityBarShort = 20.dp
    val priorityBarTall = 34.dp

    /** An icon before the title of a row: a project. */
    val rowIcon = 18.dp

    /** An icon inside the date of a row, before a due date taken from the project (R125). */
    val metaIcon = 14.dp

    /** A light icon of a field that is not set (R64). */
    val lightIcon = 20.dp

    /** The least side of a small tap target: the circle of a light icon, the list button of a card. */
    val lightTarget = 40.dp

    /** The least height of a chip and of the row of fields. */
    val chip = 32.dp

    /** The least height of a row that is tapped as a whole. */
    val touch = 48.dp

    /** A row of the panel of lists. */
    val drawerRow = 56.dp

    /** The circle of a project in the panel (R126). */
    val projectMark = 24.dp

    /** The icon before the large title of a view (R95). */
    val viewIcon = 28.dp

    /** The circle at the right edge of a row in the selection mode (R109). */
    val selectCircle = 22.dp
}

/** The corners of the shapes of the UI. */
object Corners {
    /** The bar of a priority. */
    val bar = RoundedCornerShape(2.dp)

    /** The square mark of a task (R95). */
    val mark = RoundedCornerShape(5.dp)

    /** A chip of a field and a field of text. */
    val chip = RoundedCornerShape(8.dp)

    /** A card of a task, the sheet of a new task. */
    val card = RoundedCornerShape(20.dp)

    /** A pill, a row of the panel of lists, a round mark and a button. */
    val round = CircleShape
}
