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
| Completed | finished tasks and the record of each finished repeat; Clear… at the bottom removes those older than a month, older than a year, or all of them |
| Trash | deleted tasks; they can be restored until the trash is emptied by hand |

On macOS, Settings → Sidebar → "Show Completed in the sidebar" removes the Completed view from the sidebar and from the Go menu (⌘5). It is a setting of that Mac and does not sync. It is not the per-list switch "Keep completed tasks in this list" (context menu of a list → Configure…), which decides whether finished tasks stay at the end of that one list.

Search looks through titles and notes in all lists.

## Tasks

Only the title is required. A task can also have notes, a start date, a due date, a priority, tags, a repeat rule, a reminder, attachments and subtasks.

- **Dates** are a day or a day with a time, without a time zone: "tomorrow at 9:00" stays nine in the morning after a flight. A task with a start date in the future is hidden from Today until that day.
- **Priority** is none, low, medium or high.
- **Tags** are created by typing them. A tag that no task carries disappears from the sidebar.
- **Attachments** are files and images in any number. Once downloaded to a device they open without a network. With CalDAV sync, attachments up to 5 MB are synced, up to 20 MB per task; the rest stay on the device they were added on. An image or a PDF opens inside the app: on macOS a click on the name or Space on the selected file shows it in Quick Look, and the context menu still opens it in the default app; while a file is selected Space belongs to it and not to the task, and Esc closes the card; on Android it opens full screen, where an image zooms with two fingers or a double tap and a PDF scrolls page by page; on the web PNG, JPEG, GIF, WebP and PDF open over the page, and every other file is downloaded. Images show a thumbnail in the task card.

On macOS a task opens in place in the list as an outlined card; on Android it opens as a bottom sheet over the list. The card always shows the start date and the due date. Other empty fields take no room: they are added from the "+" button.

On macOS Return on the selected row, or a double click, opens its card with the cursor at the end of the title, and Esc closes the card and hands the keyboard back to the list with the same row selected. The chevron at the end of a row only opens and closes the card. One card is open at a time. Opening another task, or moving to another row with a click or the arrow keys, closes the open card and keeps what was typed in it. A task stays open while one of its subtasks is selected or open. The card of a new task closes an open task, and opening a task closes the card of a new one the way Esc does.

On macOS ⌘N, or the "+" button in the toolbar, opens the card of a new task right in the list with every field at hand: title, notes, start date, due date, repeat, priority, tags, list and files. Return in the title creates the task. Esc creates it when it has a title and drops an empty card.

Files get into a card on macOS in three ways: the paperclip button, dropping them on the card, and ⌘V with files or an image on the clipboard. This works in the card of a new task, in the quick-entry window and in an open task. ⌘V with text on the clipboard pastes the text as usual.

Return in the notes starts a new line and Esc finishes editing. Settings → New tasks can turn that around: Return finishes, ⌥Return starts a new line. ⌘S and ⌘D open the start date and the due date from anywhere in the card; the calendar takes the arrow keys, and Return confirms. In the open date popover one key sets a common choice and closes it: T for today, M for tomorrow, W for a week from now, and a digit from 1 to 9 for that many days ahead. + and − move the day selected in the calendar forward and back and leave the popover open; ⌫ removes the date. The keys are the same in any keyboard layout, and each is shown next to its button. While the time field has the keyboard, they go to it, and Return still confirms. ⇧⌘R opens the repeat the same way. Esc in an open popover closes the popover alone and puts the keyboard back where it was; the next Esc closes the card.

### Notes in Markdown

Notes are read as Markdown and styled while you type; there is no separate preview. Headings (`#`), bold (`**`), italic (`*`), strikethrough (`~~`), inline code and code blocks, bullet and numbered lists, block quotes (`>`), a horizontal rule and links are shown formatted. The markup characters are hidden everywhere except in the paragraph, heading or list item the cursor is in, where they are shown dimmed. The note is stored exactly as typed, so sync, CalDAV and search see the plain text.

- `- [ ]` and `- [x]` are shown as a checkbox. A click on macOS or a tap on Android toggles it and saves the note. These checkboxes are part of the text; they are not subtasks.
- Return at the end of a list item starts the next one, with the next number in a numbered list and an empty checkbox in a task list. Return on an empty item removes its marker. A block quote continues the same way.
- A link opens with ⌘-click on macOS and with a tap on Android while the note is not being edited. Only `http`, `https` and `mailto` addresses are links.
- A table is laid out as a grid: aligned columns, a header row, the alignment set by `:---`, `:---:` and `---:`. On macOS and Android the grid shows while the cursor is outside the table; put the cursor into it and you edit the text as typed. There a table wider than the note, or one inside a list item or a quote, stays as typed. An image is shown as a link with its text and is not loaded. HTML is shown as typed.

In the web interface a note is shown formatted until you click it; the click opens the plain text for editing, and leaving the field saves it. Checkboxes are not toggled there. Quick entry on Android and the share sheets keep a plain text field.

Deleting and completing can be undone: ⌘Z on macOS, the Undo bar on Android. Only emptying the trash and clearing Completed ask for confirmation: both remove tasks for good. Clearing takes finished tasks with their subtasks and the records of finished repeats; open tasks and the trash stay as they are. Over CalDAV the cleared tasks end up in the trash of the other devices instead of disappearing there.

## Subtasks and projects

On macOS subtasks stay folded behind a "Subtasks 1/3" line in the open card, and a task without subtasks does not mention them: add the first one from the "+" button or the context menu.

A subtask is a full task with its own dates, priority, repeat, attachments and subtasks. Completing a task completes its open subtasks; reopening it leaves them as they are. A subtask with its own due date shows up in Today and Upcoming with the name of its parent. On macOS, while its parent is open with the subtasks unfolded, the subtask is shown only inside the parent. A subtask can be moved to another parent or made a task of its own.

A project is a top-level task marked as a project. It appears in the sidebar with a "done/total" counter and opens as its own view. A task entered in that view becomes a subtask of the project. A project can be turned back into a plain task without losing its subtasks; a completed project leaves the sidebar.

## Repeats

A repeat is set in the card of a task. On macOS the card of a new task, in the main window, in the quick-entry window and in the menu bar, always has a Repeat chip. In an open task the chip appears once a rule is set; until then Repeat is under the "+" button. ⇧⌘R opens it from anywhere in either card. On Android the card of a new task and the quick-entry window have a Repeat icon, and in the editor Repeat is under the "+" button until a rule is set. The rule counts from the due date, or from the start date when there is no due date.

Presets: every day, on weekdays, every week, every two weeks, every month, every quarter, every year.

A custom rule repeats every N days, weeks, months or years. Weekly rules take a set of weekdays; monthly rules take a day of the month or "the first … fifth, last" weekday. A rule ends never, after N repeats or on a date, and counts either from the due date or from the day the task was completed. Day 31 in a shorter month means its last day.

Completing a repeating task moves its dates to the next occurrence, reopens its subtasks and adds a record to Completed. After the last occurrence the task completes like any other.

On Android the end date of a repeat cannot be set; the web interface offers the presets only.

## Quick entry

One line becomes a task. Recognized parts are removed from the title and shown as chips before saving. Nothing has to be typed as text, though: the quick-entry window carries the same fields as the task card, and a value set in a field wins over one read from the title. Recognition can be turned off in Settings; the title is then kept as typed. Files can be added there too: on Android the paperclip in the card picks any number of them.

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

The quick-entry window starts the note with the clipboard: copy a link or a piece of text, open the window, and it is already in the note while the cursor waits in the title. This applies to the window opened with the global shortcut on macOS and from the launcher shortcut or the tile on Android; Share and the text-selection menu bring their own text. Each copy is used once, so opening the window again gives an empty note. Only text of up to 2000 characters is taken; files, images, longer text and what a password manager marks as hidden are left alone. The button next to the note removes the text in one go until you edit it. Settings → New tasks → "Start the note with the clipboard in quick entry" turns this off, and the clipboard is then not read at all. The setting belongs to the device and does not sync. Android 12 and later show their own notice when an app reads the clipboard; it appears once per copy.

Where the entry field is:

- **macOS**: the card in the main window (⌘N); a global hotkey that opens a small window over any app (⌃⌥Space by default, changeable in Settings); the menu bar item, which also lists today's tasks; the share extension; the Services menu; the `lists://add?text=…` URL.
- **Android**: the "+" button on the main screen, which opens the card of a new task as a bottom sheet and keeps it open for the next task after Done on the keyboard or the send button (back or a tap outside closes it). The card is compact: the title, one line of the note and a row of icons for the start date, the due date, the repeat, the priority, files and the list, each with its value next to it once set. The button beside the title expands the card to the full screen, where the note has room and the fields are rows with names; the same button brings it back, and nothing typed is lost. In landscape the card is always expanded. Besides the button there is a small window over the current app from Share, from the text-selection menu, from the launcher shortcut and from the quick settings tile.
- **Web**: the New task field in the task list.

## Saved filters

A filter is made with the "+" next to Filters in the sidebar on macOS (or File → New Filter…), with New filter in the drawer on Android, and from the sidebar in the web interface. It is a named view with conditions that must all hold: date (any, overdue, today, the next N days including overdue, no date), lists, tags (all of the chosen ones), a minimum priority, state (open, completed, all) and words in the title or notes. Four come ready: Next 7 days, Overdue, High priority, No date.

Filters sync like the rest of the data. Over CalDAV they are kept in a property of the Inbox calendar and are lost on servers that do not store such properties.

## Sync

Open Settings → Sync and choose the kind:

- **WebDAV**: address, user name and password. For Nextcloud and similar servers use an app password.
- **CalDAV**: address, user name and password. Lists become calendars, and tasks stay visible to other CalDAV apps.
- **Folder** (macOS and the web server): a directory, for example one that another tool keeps in sync. Android does not offer it. Changes that the other tool brings into the folder are picked up within a few seconds.

On macOS and Android, Test connection asks the server with the address, user name and password as typed, before anything is saved, and says whether it answered. For WebDAV it also says when the folder at the address does not exist yet and the first sync will create it. Saving does not require the test.

Use the same kind and the same address on every device. After that sync needs no attention: a small icon shows the state, and an error does not block work. On Android sync also runs in the background every 15 minutes, and a change made on the phone is sent even if the app is closed right after.

### Faster delivery

Storage cannot tell a device that something changed, so an edit made elsewhere waits for the next run: up to a minute in an open app. To shorten the wait, a device that uploads a change can ask the others to sync, and they do so within seconds.

- **Mac app and web server**: give them the address of an [ntfy](https://ntfy.sh) server, the public `https://ntfy.sh` or your own, in Settings → Sync → Push server and in `LISTS_PUSH_SERVER`.
- **Android**: install a [UnifiedPush](https://unifiedpush.org) app such as ntfy, open it once, then turn on Settings → Sync → "Sync at once after a change elsewhere". This works with the app closed too.

The request carries no data, only "sync now"; tasks still travel through your storage. Each device listens on a random topic name. On a server open to everyone that name is the only protection: the ntfy server can see when you edit, not what. Devices may use different servers, as long as each can reach the others'.

#### An ntfy server that requires sign-in

A server closed to anonymous users takes an access token. Create one on the server with `ntfy token add <user>` or on the account page of its web app. Lists does not take a user name and a password.

- **Mac app and web server**: in Settings → Sync turn on "The push server requires sign-in" and put the token in Push token; the web server takes it from `LISTS_PUSH_TOKEN`.
- **Android**: the ntfy app receives under the account set in it, so Lists needs nothing for that. To let the phone ask the other devices to sync, turn on Settings → Sync → "ntfy server that requires sign-in" and fill in Push server and Push token.

On the public `ntfy.sh` and on any server open to everyone leave these switches off: the fields behind them are not needed, and turning a switch off clears them.

The token is sent only to the server named in the same settings: when the device subscribes, and when it asks a device that listens on that server. Requests to any other server go without it, so keep all devices on the one server. The user behind the token needs read and write access to the topics, for example `ntfy access <user> '*' rw`; the topics of the Android ntfy app start with `up`.

When the server turns the token down, the sync settings say "The push server refused access", and the web server writes that to its log. Sync itself goes on as scheduled. The Mac keeps the token in the keychain and Android encrypts it with a key from the system keystore; it is never written to the storage.

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
| T, M, W | in the open date popover: today, tomorrow, in a week |
| 1 … 9 | in the open date popover: in that many days |
| + and − | in the open date popover: a day later, a day earlier |
| ⌫ | in the open date popover: remove the date |
| ⇧⌘R | repeat of the open card |
| ⌘V | attach the files or the image on the clipboard to the open card |
| ↑ ↓ | select |
| Enter | open the selected task with the cursor in its title; close it when it is open |
| Tab | from the title to the notes, from the notes to the chips of the card, then from chip to chip and back to the title |
| ⇧Tab | back through the chips, from the first one to the notes |
| ⌥Tab | a tab character in the notes |
| Space or Return on a chip | what a click on it does: its date, repeat or tag popover, its menu, or the removal of a tag |
| Esc | close the open popover of a chip; without one, close the open card and go back to the list |
| Space or ⌘Enter | complete |
| ⌘T | due today |
| ⌘] and ⌘[ | make a subtask, move a level up |
| ⌘1 … ⌘5 | views |
| ⌘F | search |
| ⌘Z | undo |
| ⌃⌥Space | quick entry from any app |

Text size (five steps) and typeface (system, rounded, serif, monospaced) are chosen in Settings.

## Light and dark

By default the apps look the way the system does, and follow it when it switches between light and dark on a schedule. Appearance chooses otherwise: Same as the system, Light or Dark. It is in Settings on macOS, in Settings in the drawer on Android, and at the bottom of the sidebar in the web interface. The choice applies at once and to every window, is kept by the device (by the browser in the web interface) and does not sync. List colours and the red of an overdue date are the same in both looks.

## Gestures on Android

Swipe right to complete, swipe left to set the due date; a swipe to the right that starts at the left edge of the screen opens the panel with the lists instead. Long-press for the menu: due date, priority, move to list, add subtask, duplicate, delete.

## Import

| Source | File |
|---|---|
| 2Do | backup, `.2dodb` |
| Todoist | CSV template |
| Trello | board exported as JSON |
| Microsoft To Do | lists as JSON |

Import from File → Import… on macOS, from Settings on Android, from the sidebar in the web interface. Importing the same file again updates what is already there. What each importer carries over, and what it cannot, is in [specs/import.md](specs/import.md) (in Russian).
