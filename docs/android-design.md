# Android: theme, tokens and screenshots

How the Android screens take their measures and colours, and how a change to them is checked. The code is in `android/app/src/main/java/org/evsyukov/lists/ui/theme/`; the rules below say which token goes where (#369).

## Theme

`ListsTheme(dark, dynamic)` is the theme of every screen. It takes the colour scheme of the look chosen in the settings (system, light or dark). With `dynamic`, Android 12 and later take the palette of the wallpaper; before Android 12 the Material baseline is used. `AppTheme` in `MainActivity.kt` is `ListsTheme` with the look of the settings and the colour of the system bars. Type and shapes are the Material ones: the text size of the settings (R100) and of the system scales every role.

## Tokens

`Tokens.kt` holds the measures; a screen does not write a number of its own for a measure that is listed here.

| Token | Value | Where |
|---|---|---|
| `Space.xxs` | 3 dp | between an icon and the text it marks |
| `Space.xs` | 4 dp | inside small elements, the start padding of a row |
| `Space.s` | 6 dp | between chips and pills in a row |
| `Space.chipGap` | 5 dp | between the icon and the text of a chip |
| `Space.m` | 8 dp | between fields; the vertical padding of the panel |
| `Space.chipInset` | 10 dp | the side padding of a chip; after the bar of a priority |
| `Space.l` | 12 dp | between an icon and its label; the side padding of the panel |
| `Space.xl` | 16 dp | the margin of a screen and of a row |
| `Space.xxl` | 20 dp | above the heading of a group |
| `Space.xxxl` | 24 dp | the end padding of a row of the panel |
| `Sizes.mark` | 16 dp | the completion mark (R95), the icon of a chip |
| `Sizes.priorityBar` | 3 × 20 or 34 dp | the bar of a priority (R72), one line or two |
| `Sizes.chip` | 32 dp | the least height of a chip and of the row of fields |
| `Sizes.lightTarget` | 40 dp | the circle a light icon is tapped in (R64) |
| `Sizes.touch` | 48 dp | the least height of a row tapped as a whole |
| `Corners.bar`, `mark`, `chip`, `card` | 2, 5, 8, 20 dp | the bar of a priority, the square mark, a chip, a card |
| `Corners.round` | circle | a pill, a row of the panel, a round mark, a button |

The rows of the panel of lists follow the row spacing of R122 (48, 52 or 56 dp, R158), as the rows of a list do. A value that only one element has, such as the 88 dp kept free under the last row for the add button, stays next to that element with a comment that says why.

## Colours

The colour scheme of the theme gives every colour that only marks a surface, a text or an outline. A colour that carries a meaning of its own is named in `Colors.kt` and does not change with the palette:

- `PriorityColors` — the bar of a priority (R72): red high, orange medium, blue low; the chip of the priority field is orange whatever the level, the level is its text.
- `ViewTint` and `viewTint()` — the icons of the built-in views (R79), the same as on macOS, a lighter shade in the dark look.
- A late date is `colorScheme.error`; a date taken from the project (R125) is `outline`.
- The colour of a list is the one chosen for it (R2); a list without one takes `primary`.

## Text

`Type.kt` names the roles of text over the Material type scale: `rowTitle`, `rowMeta`, `label`, `pill`, `viewTitle`, `groupHeading`, `sectionHeading`. A screen asks for a role, not for a size.

## Screenshots

The building blocks are drawn on the JVM by Robolectric and compared by Roborazzi: `android/app/src/test/java/org/evsyukov/lists/screenshots/`. The tests use the fixed palette (`dynamic = false`) so that a picture does not depend on the wallpaper of the machine, a phone of 411 × 914 dp at 420 dpi, and the light and the dark look; one test draws the largest system text size.

- `make android` (and CI) compares the pictures with `android/app/src/test/screenshots/`; a difference fails the build, and the picture drawn and the difference are left in `android/app/build/outputs/roborazzi/`.
- `make android-screenshots` records the pictures anew. Run it after a change that is meant to show, look at the new pictures, and commit them with the change.

`ui/Catalog.kt` holds the same blocks as Compose previews for the IDE.
