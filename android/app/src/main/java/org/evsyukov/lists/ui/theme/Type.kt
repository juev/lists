package org.evsyukov.lists.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight

/*
 * The roles of text (#369). The sizes are those of the Material type scale, so the text size chosen
 * in the settings (R100) and in the system scales them all; a role names what the text is.
 */

/** The title of a task in a row. */
val Typography.rowTitle: TextStyle get() = bodyLarge

/** What stands under or beside the title of a row: the list, the project, the date. */
val Typography.rowMeta: TextStyle get() = bodySmall

/** The value in a chip of a field, a row of the panel of lists and its counter. */
val Typography.label: TextStyle get() = labelLarge

/** A pill: what quick entry read from the line (R63). */
val Typography.pill: TextStyle get() = labelMedium

/** The large title of a view (R95). */
val Typography.viewTitle: TextStyle get() = headlineMedium.copy(fontWeight = FontWeight.Bold)

/** The heading of a group of rows: Overdue, a day of Upcoming, a list of All. */
val Typography.groupHeading: TextStyle get() = titleSmall.copy(fontWeight = FontWeight.Bold)

/** The heading of a section of the panel of lists. */
val Typography.sectionHeading: TextStyle get() = labelLarge
