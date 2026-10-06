# Using Lists

The apps for macOS and Android and the web interface work on the same data and offer the same actions; where a platform differs, the section says so. Installation is described in the [README](../README.md#install).

## Lists and views

A task belongs to one list. Inbox always exists and takes everything that has no list.

Each list has a name, a colour, an icon, a sort order (manual, by due date, by priority, by title), a switch for showing completed tasks, and defaults for new tasks: a priority and an optional due date of today. Lists can be archived and brought back. These settings sync with the tasks.

The fixed views next to the lists:

| View | Shows |
|---|---|
| Inbox | tasks without a list |
| Today | tasks due today or earlier, and tasks without a due date whose start date has come |
| Upcoming | tasks with a future date, by day |
| All | every open task |
| Completed | finished tasks and the record of each finished repeat |
| Trash | deleted tasks; they can be restored until the trash is emptied by hand |

Search looks through titles and notes in all lists.

## Tasks

Only the title is required. A task can also have notes, a start date, a due date, a priority, tags, a repeat rule, a reminder, attachments and subtasks.

- **Dates** are a day or a day with a time, without a time zone: "tomorrow at 9:00" stays nine in the morning after a flight. A task with a start date in the future is hidden from Today until that day.
- **Priority** is none, low, medium or high.
- **Tags** are created by typing them. A tag that no task carries disappears from the sidebar.
- **Attachments** are files and images in any number. Once downloaded to a device they open without a network. With CalDAV sync, attachments up to 5 MB are synced.

On macOS a task opens in place in the list as an outlined card; on Android it opens as a bottom sheet over the list. The card always shows the start date and the due date. Other empty fields take no room: they are added from the "+" button.

On macOS Return on the selected row, or a double click, opens its card with the cursor at the end of the title, and Esc closes the card and hands the keyboard back to the list with the same row selected. The chevron at the end of a row only opens and closes the card. One card is open at a time. Opening another task, or moving to another row with a click or the arrow keys, closes the open card and keeps what was typed in it. A task stays open while one of its subtasks is selected or open. The card of a new task closes an open task, and opening a task closes the card of a new one the way Esc does.

On macOS ⌘N, or the "+" button in the toolbar, opens the card of a new task right in the list with every field at hand: title, notes, start date, due date, priority, tags, list and files. Return in the title creates the task. Esc creates it when it has a title and drops an empty card.

Files get into a card on macOS in three ways: the paperclip button, dropping them on the card, and ⌘V with files or an image on the clipboard. This works in the card of a new task, in the quick-entry window and in an open task. ⌘V with text on the clipboard pastes the text as usual.

Return in the notes starts a new line and Esc finishes editing. Settings → New tasks can turn that around: Return finishes, ⌥Return starts a new line. ⌘S and ⌘D open the start date and the due date from anywhere in the card; the calendar takes the arrow keys, and Return confirms.

Deleting and completing can be undone: ⌘Z on macOS, the Undo bar on Android. Only emptying the trash asks for confirmation.

## Subtasks and projects

On macOS subtasks stay folded behind a "Subtasks 1/3" line in the open card, and a task without subtasks does not mention them: add the first one from the "+" button or the context menu.

A subtask is a full task with its own dates, priority, repeat, attachments and subtasks. Completing a task completes its open subtasks; reopening it leaves them as they are. A subtask with its own due date shows up in Today and Upcoming with the name of its parent. On macOS, while its parent is open with the subtasks unfolded, the subtask is shown only inside the parent. A subtask can be moved to another parent or made a task of its own.

A project is a top-level task marked as a project. It appears in the sidebar with a "done/total" counter and opens as its own view. A task entered in that view becomes a subtask of the project. A project can be turned back into a plain task without losing its subtasks; a completed project leaves the sidebar.

## Repeats

Presets: every day, on weekdays, every week, every two weeks, every month, every quarter, every year.

A custom rule repeats every N days, weeks, months or years. Weekly rules take a set of weekdays; monthly rules take a day of the month or "the first … fifth, last" weekday. A rule ends never, after N repeats or on a date, and counts either from the due date or from the day the task was completed. Day 31 in a shorter month means its last day.

Completing a repeating task moves its dates to the next occurrence, reopens its subtasks and adds a record to Completed. After the last occurrence the task completes like any other.

On Android the end date of a repeat cannot be set; the web interface offers the presets only.

## Quick entry

One line becomes a task. Recognized parts are removed from the title and shown as chips before saving. Nothing has to be typed as text, though: the quick-entry window carries the same fields as the task card, and a value set in a field wins over one read from the title. Recognition can be turned off in Settings; the title is then kept as typed. Files can be added there too: on Android the "File or image" chip picks any number of them.

| Typed | Meaning |
|---|---|
| `#tag` | tag |
| `@List` | list |
| `!`, `!!`, `!!!` | low, medium, high priority |
| `today`, `tomorrow`, a weekday | due date |
| `DD.MM`, `DD.MM.YYYY` | due date |
| `HH:MM` | time of the due date |

Dates are understood in English and in Russian. Example: `buy milk tomorrow 18:30 !! #home @Shopping` creates "buy milk" due tomorrow at 18:30 with medium priority and the tag "home" in the list Shopping.

Settings → New tasks (Settings in the drawer on Android) chooses the list a task goes to when neither the line nor the view names one: Inbox, the list used last, or a fixed list.

Where the entry field is:

- **macOS**: the card in the main window (⌘N); a global hotkey that opens a small window over any app (⌃⌥Space by default, changeable in Settings); the menu bar item, which also lists today's tasks; the share extension; the Services menu; the `lists://add?text=…` URL.
- **Android**: the bar at the bottom of the main screen; a small window over the current app from Share, from the text-selection menu, from the launcher shortcut and from the quick settings tile.
- **Web**: the New task field in the task list.

## Saved filters

A filter is made with the "+" next to Filters in the sidebar on macOS (or File → New Filter…), with New filter in the drawer on Android, and from the sidebar in the web interface. It is a named view with conditions that must all hold: date (any, overdue, today, the next N days including overdue, no date), lists, tags (all of the chosen ones), a minimum priority, state (open, completed, all) and words in the title or notes. Four come ready: Next 7 days, Overdue, High priority, No date.

Filters sync like the rest of the data. Over CalDAV they are kept in a property of the Inbox calendar and are lost on servers that do not store such properties.

## Sync

Open Settings → Sync and choose the kind:

- **WebDAV**: address, user name and password. For Nextcloud and similar servers use an app password.
- **CalDAV**: address, user name and password. Lists become calendars, and tasks stay visible to other CalDAV apps.
- **Folder** (macOS and the web server): a directory, for example one that another tool keeps in sync. Android does not offer it.

Use the same kind and the same address on every device. After that sync needs no attention: a small icon shows the state, and an error does not block work. On Android sync also runs in the background every 15 minutes.

Edits are saved locally at once. Two devices that change different fields of one task both keep their change; when they change the same field, the later edit wins. How the two kinds compare is in the [README](../README.md#sync).

## Notifications

Each device has its own notification settings, and they do not sync:

- whether to show notifications at all;
- how long before a timed due date to remind: at the time, from 5 minutes to a day before. Several can be on at once, for example a day before and again 15 minutes before;
- at what time to remind about tasks due on a day;
- an optional summary of the day and its time;
- on macOS, the sound.

A reminder set on a task itself replaces the one derived from its due date. The web interface does not notify.

## Keyboard on macOS

| Keys | Action |
|---|---|
| ⌘N | new task, as a card in the list |
| ⌘S and ⌘D | start date and due date of the open card |
| ⌘V | attach the files or the image on the clipboard to the open card |
| ↑ ↓ | select |
| Enter | open the selected task with the cursor in its title; close it when it is open |
| Tab | from the title to the notes |
| Esc | close the open card and go back to the list |
| Space or ⌘Enter | complete |
| ⌘T | due today |
| ⌘] and ⌘[ | make a subtask, move a level up |
| ⌘1 … ⌘5 | views |
| ⌘F | search |
| ⌘Z | undo |
| ⌃⌥Space | quick entry from any app |

Text size (five steps) and typeface (system, rounded, serif, monospaced) are chosen in Settings.

## Gestures on Android

Swipe right to complete, swipe left to set the due date, long-press for the menu: due date, priority, move to list, add subtask, duplicate, delete.

## Import

| Source | File |
|---|---|
| 2Do | backup, `.2dodb` |
| Todoist | CSV template |
| Trello | board exported as JSON |
| Microsoft To Do | lists as JSON |

Import from File → Import… on macOS, from Settings on Android, from the sidebar in the web interface. Importing the same file again updates what is already there. What each importer carries over, and what it cannot, is in [specs/import.md](specs/import.md) (in Russian).
