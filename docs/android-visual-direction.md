# Android: the visual direction

The record of #368: two directions for a refresh of the Android look were compared, one was chosen, and the rest was left out with the reasons. The decisions of #161 (one-line titles, a small muted mark, the large title, the constant blue round "+" button, bottom sheets, the panel of lists and the dynamic palette) were the baseline; nothing here changes them.

## How the directions were compared

A mock-up shows the six key screens three times with the same demo data (`cargo run --example demo`, plus long titles and a busy list): the app as it is, direction A and direction B. The screens are Today, a list, the card of an open task, the card of a new task over the keyboard, the panel of lists and the settings. Each screen switches between the light and the dark look and between the normal and a large text size (×1.3, the "Larger" step of R100).

Mock-up: <https://claude.ai/artifact/G5QKLex9opmkC37JxSoCDq> (private to the owner of the project). The screens are drawn in HTML from the code and the specifications, not from the running app; sizes follow the tokens of `docs/android-design.md`, colours are a fixed palette in place of the wallpaper one.

- **A · Compact and restrained**, after Things and 2Do: rows at the "Compact" spacing of R122 (48 dp, the least a row may be because of the touch zone of its mark), quiet uppercase headings of sections, the list of a task as a coloured dot beside the title in mixed views, a panel with 48 dp rows and sections that fold.
- **B · Selective Material 3 Expressive**: the rows of a group in a rounded container, two lines in every view (the list and the date as a chip under the title), a larger title on a tonal tile, tonal section labels, a "New task" button with a label, a larger corner on sheets and a round mark that fills when done.

## Assessment

| | Now | A | B |
|---|---|---|---|
| Rows of a list on a 844 dp high phone, normal text | about 14 | about 15 (Compact spacing) | about 10 |
| Rows of Today | about 11 (two lines where lists mix, R72) | about 13 (one line) | about 9 |
| Title against metadata | title first, the list under it in mixed views | title first, the list squeezed beside it | title first, metadata under it in every view |
| Touch targets | mark 48 dp, rows 52 dp | 48 dp | 48 dp mark, 64–68 dp rows |
| Large text (×1.3) | rows grow, titles cut with an ellipsis | the dot and the list name take the room of the title first | rows grow most, fewest on screen |
| Dark look | as now | as now | the containers add a second surface level to the screen |
| Adding and editing | unchanged | unchanged | unchanged; the labelled button covers more of the last row |

The counts are read off the mock-up at its normal text size; the app with the system font of a given phone differs by a row or so.

## Decision

Direction A, as the app already follows it. The current screens are direction A in every point but two: the panel of lists, whose 56 dp rows and fixed sections take a whole screen once there are a few lists, projects and filters, and the density, which R122 already lets the user choose. So the refresh is one change, split into its own issue:

- **The sections of the panel of lists fold** (#380; Lists, Projects, Filters, Tags): a tap on the heading of a section folds and unfolds it, the state is kept on the device, and the rows of the panel follow the spacing of R122.

Left out, with the reason:

- **One line in mixed views (A).** The name of the list beside the title takes its room first, so with large text or a long title the title is cut sooner; R72's second line keeps the whole title width. One-line titles (#99) stay as they are.
- **Rows in containers, two lines everywhere, the labelled button (B).** About a third fewer tasks on a screen for the same content, and the labelled button replaces the constant round one of #161. The containers and tonal labels add a coloured surface to every row and heading without making a title easier to read.
- **The round mark that fills when done (B).** #161 chose a small muted square mark; a filled one is louder than the title.
- **A larger title on a tonal tile and a larger corner on sheets (B).** A change of style without a gain in reading or reach.
- **Motion.** Neither direction needs new animation, so nothing new depends on the system setting that removes animations.
- **Bottom navigation.** Not proposed by either direction: the panel stays, as #99 and #161 decided.

No direction needs a new framework, a change of the core or of sync, or a dependency beyond Material 3.
