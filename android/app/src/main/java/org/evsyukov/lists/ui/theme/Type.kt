package org.evsyukov.lists.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/*
 * The roles of text (#369). The sizes are those of the Material type scale, so the text size chosen
 * in the settings (R100) and in the system scales them all; a role names what the text is.
 */

/** The title of a task in a row (R159: medium weight). */
val Typography.rowTitle: TextStyle get() = bodyLarge.copy(fontWeight = FontWeight.Medium)

/** What stands under or beside the title of a row: the list, the project, the date. */
val Typography.rowMeta: TextStyle get() = bodySmall

/** The value in a chip of a field, a row of the panel of lists and its counter. */
val Typography.label: TextStyle get() = labelLarge

/** A pill: what quick entry read from the line (R63). */
val Typography.pill: TextStyle get() = labelMedium

/** The large title of a view (R95, R159: larger and heavier). */
val Typography.viewTitle: TextStyle get() = headlineLarge.copy(fontWeight = FontWeight.ExtraBold, letterSpacing = (-0.5).sp)

/** The heading of a group of rows: Overdue, a day of Upcoming, a list of All; a tonal pill (R159). */
val Typography.groupHeading: TextStyle get() = labelLarge.copy(fontWeight = FontWeight.SemiBold)

/** The title of a task in a card (R159). */
val Typography.cardTitle: TextStyle get() = titleLarge.copy(fontWeight = FontWeight.SemiBold)

/** The heading of a section of the panel of lists. */
val Typography.sectionHeading: TextStyle get() = labelLarge

/** The title being typed in the card of a new task (R159). */
val Typography.entryTitle: TextStyle get() = titleMedium.copy(fontWeight = FontWeight.SemiBold)
