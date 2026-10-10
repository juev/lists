# Using Lists

The apps for macOS and Android and the web interface work on the same data and offer the same actions; where a platform differs, the section says so. Installation is described in the [README](../README.md#install).

## Lists and views

A task belongs to one list. Inbox always exists and takes everything that has no list.

Each list has a name, a colour, an icon, a sort order (manual, by due date, by priority, by title), a switch for showing completed tasks, and defaults for new tasks: a priority and an optional due date of today. Lists can be archived and brought back. These settings sync with the tasks. A list is created with the "+" next to the heading Lists, or from the File menu on macOS, and the lists are put in order by hand.

The fixed views next to the lists:

| View | Shows |
|---|---|
| Inbox | tasks without a list |
| Today | tasks due today or earlier, and tasks without a due date whose start date has come; on macOS and Android in two groups, Overdue for the tasks whose due date has passed and Today for the rest |
| Upcoming | tasks with a future date, by day |
| All | every open task |
| Completed | finished tasks and the record of each finished repeat, tasks marked "won't do" among them; Clear… at the bottom removes those older than a month, older than a year, or all of them |
| Won't do | the part of Completed that was closed as "won't do"; it has no Clear… of its own |
| Trash | deleted tasks; they can be restored until the trash is emptied by hand |

On macOS, Settings → General → Sidebar says for each built-in view (Inbox, Today, Upcoming, All, Completed, Won't do, Trash) when it has a row in the sidebar: always, when it holds something, or never. Inbox, Today, Upcoming and All start as "always"; Completed, Won't do and Trash appear when they hold something. A view without a row is not opened from the Go menu or by its key (⌘1–⌘6) either, and when the row of the view on screen goes away the app goes to Inbox. It is a setting of that Mac and does not sync. It is not the per-list switch "Keep completed tasks in this list" (context menu of a list → Configure…), which decides whether finished tasks stay at the end of that one list.

Search looks through titles and notes in all lists. On macOS it stands behind the magnifier at the top right of the window: a click on it or ⌘F opens the field, and Esc clears and closes it.

## Tasks

Only the title is required. A task can also have notes, a start date, a due date, a priority, tags, a repeat rule, a reminder, attachments and subtasks.

In the list on macOS and Android a task takes one line. Before the title stand the mark of a project and the priority, and in a view that mixes lists the title of the parent of a subtask. After the title stand small marks for what is set: a repeat, a note, attachments, subtasks. The marks carry no text; the note, the files and the subtasks are read in the card, and so are the start date, the tags and the list. The due date stands at the right edge, in red when it has passed. Where the heading of the group already names the day, in Today and in Upcoming, only the time is written. The title itself takes one line: a title that does not fit ends with an ellipsis, and the card of the task shows the full title, wrapped over as many lines as it needs. Return in the title still finishes the edit. What is being typed into the title or the note of an open task is saved when the app quits or goes to the background, on macOS and on Android.

- **Dates** are a day or a day with a time, without a time zone: "tomorrow at 9:00" stays nine in the morning after a flight. A task with a start date in the future is hidden from Today until that day.
- **Priority** is none, low, medium or high.
- **Tags** are created by typing them. A tag that no task carries disappears from the sidebar.
- **Attachments** are files and images in any number. Once downloaded to a device they open without a network. A file whose name does not tell its type is shown by its content: "Image" that holds a JPEG is listed as "Image.jpg" and opens as a picture. A downloaded file can be saved outside the app and handed to another one: Save As… under the ⋯ button of the file on macOS, or a drag from the card to Finder; Save to…, Share and Open in another app in the ⋮ menu of the file on Android, where the viewer of an image or a PDF offers saving and sharing as well. In the web interface a file is added with "Attach file" in the card of a task. A task with more than one file saves them all in one action: Save All… in the menu of a file or of the task on macOS asks for a folder and writes every file there; Save all to… in the ⋮ menu of a file or of the task on Android does the same, and Share all hands every file to another app. Nothing in the folder is replaced: a file whose name is taken is saved next to it under a free name, such as "Image 2.jpg". Files that are not downloaded yet are downloaded first; a file that could not be downloaded or written is named in a message, and the rest are saved. A task reaches the other devices before the content of its files: the attachment is listed as not downloaded yet and arrives a little later by itself. A click or a tap on such an attachment downloads it right away and opens it; in the web interface the server fetches the file from the storage first. When the file has not reached the storage yet, its row says that the download failed, and the next click tries again. The sync icon, and the sync button of the web interface, tell how many attachments still wait. With CalDAV sync, attachments up to 5 MB are synced, up to 20 MB per task; the rest stay on the device they were added on. An image or a PDF opens inside the app: on macOS a click on the name or Space on the selected file shows it in Quick Look, and the context menu still opens it in the default app; while a file is selected Space belongs to it and not to the task, and Esc closes the card; on Android it opens full screen, where an image zooms with two fingers or a double tap and a PDF scrolls page by page; on the web PNG, JPEG, GIF, WebP and PDF open over the page, and every other file is downloaded. Images show a thumbnail in the task card.

On macOS a task opens in place in the list as an outlined card; on Android it opens as a bottom sheet over the list. On macOS the card always shows the start date and the due date, and other empty fields take no room: they are added from the "+" button. On Android the card has one row of fields: a field that is set stands at the left as a chip with its value, a field that is not set is a light icon at the right. A tap on either opens the choice; a tap on the chip of a tag removes the tag. Subtasks have a round mark, and a completed one turns grey. Dragging the handle of the sheet up stretches it to the full screen without changing what it shows; dragging the handle down brings it back to the height of its content, and one more drag down closes it.

On Android a tap on a date offers Today, Tomorrow, In a week and "Pick a date…". The first three set the day with one tap. "Pick a date…" opens a calendar with a Time row under it: tap the row to give the chosen day a time, or press Done to keep the day alone. A date that is already set also gets its time changed or removed from the first menu.

On Android the title, the note, a subtask and the name of a list or a filter start with a capital letter when the keyboard has auto-capitalisation turned on; a tag, the search and the tag and text fields of a filter are typed as they are. Suggestions and autocorrection follow the settings of the keyboard.

On macOS Return on the selected row, or a double click, opens its card with the cursor at the end of the title, and Esc closes the card and hands the keyboard back to the list with the same row selected. Esc closes the card of the selected row as well when the list has the keyboard, after a click on the chevron or inside the card. The chevron at the end of a row opens the card; an open card has no chevron and is closed by Esc, by Return or a double click on its title row, or by opening another task. In the card what is set (dates, repeat, reminder, priority, tags) stands at the left as chips with their values, and what is not set at the right as light icons: a click on an icon sets the field. One card is open at a time. Opening another task, or moving to another row with a click or the arrow keys, closes the open card and keeps what was typed in it. A task stays open while one of its subtasks is selected or open. The card of a new task closes an open task, and opening a task closes the card of a new one the way Esc does.

On macOS ⌘N, or the "+" button at the top right of the window, opens the card of a new task right in the list with every field at hand: title, notes, start date, due date, repeat, priority, tags, list and files. Return in the title creates the task, and so does ⌘Return from any field of the card. Esc cancels: the card closes and nothing is created. What is set stands at the left of the row of fields as a chip with its value; what is not set stands at the right as an icon.

Files get into a card on macOS in three ways: the paperclip button, dropping them on the card, and ⌘V with files or an image on the clipboard. This works in the card of a new task, in the quick-entry window and in an open task. ⌘V with text on the clipboard pastes the text as usual.

Return in the notes starts a new line and Esc finishes editing. Settings → Tasks → New tasks can turn that around: Return finishes, ⌥Return starts a new line. ⌘S and ⌘D open the start date and the due date from anywhere in the card; the calendar takes the arrow keys, and Return confirms. In the open date popover one key sets a common choice and closes it: T for today, M for tomorrow, W for a week from now, and a digit from 1 to 9 for that many days ahead. + and − move the day selected in the calendar forward and back and leave the popover open; ⌫ removes the date. The keys are the same in any keyboard layout, and each is shown next to its button. While the time field has the keyboard, they go to it, and Return still confirms. ⇧⌘R opens the repeat the same way. Esc in an open popover closes the popover alone and puts the keyboard back where it was; the next Esc closes the card.

### Notes in Markdown

Notes are read as Markdown and styled while you type; there is no separate preview. Headings (`#`), bold (`**`), italic (`*`), strikethrough (`~~`), inline code and code blocks, bullet and numbered lists, block quotes (`>`), a horizontal rule and links are shown formatted. The markup characters are hidden everywhere except in the paragraph, heading or list item the cursor is in, where they are shown dimmed. The note is stored exactly as typed, so sync, CalDAV and search see the plain text.

- `- [ ]` and `- [x]` are shown as a checkbox. A click on macOS or a tap on Android toggles it and saves the note. These checkboxes are part of the text; they are not subtasks.
- Return at the end of a list item starts the next one, with the next number in a numbered list and an empty checkbox in a task list. Return on an empty item removes its marker. A block quote continues the same way.
- A link opens with a click on macOS and with a tap on Android, also while the note is being edited. To change the text of a link, put the cursor next to it and move in with the arrow keys; a long press on Android selects a word of it. Only `http`, `https` and `mailto` addresses are links; the scheme may be typed in any case, so `Https://example.org`, as a phone keyboard starts a sentence, is a link too.
- A table is laid out as a grid: aligned columns, a header row, the alignment set by `:---`, `:---:` and `---:`. On macOS and Android the grid shows while the cursor is outside the table; put the cursor into it and you edit the text as typed. There a table wider than the note, or one inside a list item or a quote, stays as typed. An image is shown as a link with its text and is not loaded. HTML is shown as typed.

In the web interface a note is shown formatted until you click it; the click opens the plain text for editing, and leaving the field saves it. Checkboxes are not toggled there. Quick entry on Android and the share sheets keep a plain text field.

A completed task does not leave its view at once: it stays where it was, struck through and dimmed, for the time chosen in Settings → General → "Completed tasks leave the view" (on macOS: Settings → General → Completed tasks → Leave the view; at once, after 5 or 15 seconds, or at the end of the day; after 5 seconds unless changed; in the web interface the choice is at the bottom of the sidebar), and a tap on its mark during that time reopens it. In a list that keeps its completed tasks, in a project and in a filter that shows all tasks it then moves to the end instead of leaving. "At the end of the day" keeps it until midnight on the clock of the device. A time in minutes chosen in an earlier version stays in force, and in the list of choices, until another one is picked; a device that still runs such a version keeps completed tasks for 5 minutes while one of the new choices is in force. The setting is shared by all devices and syncs; over CalDAV it does not travel, so there it is set on each device.

A task that will not be done, but should not be deleted either, is closed as "won't do": the item Won't do in the context menu of a task on macOS, in the long-press menu of a task on Android, and the button in the card in the web interface. The mark then shows a cross in place of the tick. From there the task behaves like a completed one: it stays in view for the same time, a tap on its mark reopens it, its open subtasks get the same mark, and a repeating task moves to its next occurrence, leaving a "won't do" record. Such tasks are listed in Completed and in the Won't do view. They are left out of both numbers of the "done/total" counter of a project and of a task with subtasks. Over CalDAV such a task has `STATUS:CANCELLED`, and a task cancelled in another CalDAV app arrives as "won't do". A device with an earlier version of the app shows such a task as completed.

Deleting can be undone: ⌘Z on macOS, the Undo bar on Android. Completing is undone with ⌘Z on macOS or by tapping the mark again; the Undo bar after completing appears only when completed tasks leave at once. Only emptying the trash and clearing Completed ask for confirmation: both remove tasks for good. Clearing takes finished tasks with their subtasks and the records of finished repeats; open tasks and the trash stay as they are. Over CalDAV the cleared tasks end up in the trash of the other devices instead of disappearing there.

## Subtasks and projects

On macOS subtasks stay folded behind a "Subtasks 1/3" line in the open card, and a task without subtasks does not mention them: add the first one from the "+" button or the context menu.

A subtask is a full task with its own dates, priority, repeat, attachments and subtasks. Completing a task completes its open subtasks; reopening it leaves them as they are. A subtask with its own due date shows up in Today and Upcoming with the name of its parent. On macOS, while its parent is open with the subtasks unfolded, the subtask is shown only inside the parent. A subtask can be moved to another parent or made a task of its own.

A project is a top-level task marked as a project. It appears in the sidebar with a "done/total" counter and opens as its own view. A task entered in that view becomes a subtask of the project. A project can be turned back into a plain task without losing its subtasks; a completed project leaves the sidebar.

## Repeats

A repeat is set in the card of a task. On macOS the card of a new task, in the main window, in the quick-entry window and in the menu bar, always has a Repeat chip. In an open task the chip appears once a rule is set; until then Repeat is under the "+" button. ⇧⌘R opens it from anywhere in either card. On Android the card of a new task and the quick-entry window have a Repeat icon, and in the editor Repeat is a light icon in the row of fields until a rule is set. The rule counts from the due date, or from the start date when there is no due date.

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

Settings → Tasks → New tasks (Settings in the drawer on Android) chooses the list a task goes to when neither the line nor the view names one: Inbox, the list used last, or a fixed list.

In the quick-entry window on macOS a strip at the bottom shows the list the task goes to and holds Cancel and Save. The quick-entry window starts the note with the clipboard: copy a link or a piece of text, open the window, and it is already in the note while the cursor waits in the title. On macOS that text is shown as a block of at most three lines marked "From the clipboard", with a button that removes it; a click on the block opens it as an ordinary note. This applies to the window opened with the global shortcut on macOS and from the launcher shortcut or the tile on Android; Share and the text-selection menu bring their own text. Each copy is used once, so opening the window again gives an empty note. Only text of up to 2000 characters is taken; files, images, longer text and what a password manager marks as hidden are left alone. The button next to the note removes the text in one go until you edit it. Settings → Tasks → New tasks → "Start the note with the clipboard in quick entry" turns this off, and the clipboard is then not read at all. The setting belongs to the device and does not sync. Android 12 and later show their own notice when an app reads the clipboard; it appears once per copy.

Where the entry field is:

- **macOS**: the card in the main window (⌘N); a global hotkey that opens a small window over any app (⌃⌥Space by default, changeable in Settings → Tasks → Quick Entry); the menu bar item, which also lists today's tasks; the share extension; the Services menu; the `lists://add?text=…` URL.
- **Android**: the "+" button on the main screen, which opens the card of a new task as a bottom sheet and keeps it open for the next task after Done on the keyboard or Save (back or a tap outside closes it). The card is compact: the title, the note, a row of fields and a strip at the bottom with the list the task goes to and Save. In the row the start date, the due date, the repeat, the priority and files are light icons at the right until they are set, and chips with their value at the left after that; what is read from the title stands there as chips as well. The note grows with its text up to five lines and scrolls inside itself after that. Dragging the handle of the card up expands it to the full screen, where the note has room and the fields are rows with names; dragging the handle down brings it back, and nothing typed is lost. A drag down on the compact card closes it. Closing the card without saving discards what was entered; for three seconds a bar at the bottom offers Restore, which opens the card again with everything in it. Besides the button there is a small window over the current app from Share, from the text-selection menu, from the launcher shortcut and from the quick settings tile. Its card has the same handle. That window turns with the app under it, and in landscape its card is always expanded.
- **Web**: the New task field in the task list.

A new task takes its place from the view it is created in: the list on screen, the project it is added to, or the default list from the settings where the view has no list of its own (Today, Upcoming, All, a tag, a filter). The view sets nothing else. A task created in Today has no due date, and a task created in the view of a tag has no tag, until you set them in the card or type them in the title; without them the task is not in that view once it is saved. The defaults of a list, a priority and "due today", stand next to their icons in the card on macOS and Android before the task is saved. They follow the list chosen in the card and can be changed or removed like a value you picked, and what the title says wins over them.

## Saved filters

A filter is made with the "+" next to Filters in the sidebar on macOS (or File → New Filter…), with New filter in the drawer on Android, and from the sidebar in the web interface. It is a named view with conditions that must all hold: date (any, overdue, today, the next N days including overdue, no date), lists, tags (all of the chosen ones), a minimum priority, state (open, completed, won't do, all) and words in the title or notes. Four come ready: Next 7 days, Overdue, High priority, No date.

Filters sync like the rest of the data. Over CalDAV they are kept in a property of the Inbox calendar and are lost on servers that do not store such properties.

## Sync

Open Settings → Sync and choose the kind:

- **WebDAV**: address, user name and password. For Nextcloud and similar servers use an app password.
- **CalDAV**: address, user name and password. Lists become calendars, and tasks stay visible to other CalDAV apps.
- **Folder** (macOS and the web server): a directory, for example one that another tool keeps in sync. Android does not offer it. Changes that the other tool brings into the folder are picked up within a few seconds.

On macOS and Android, Test connection asks the server with the address, user name and password as typed, before anything is saved, and says whether it answered. For WebDAV it also says when the folder at the address does not exist yet and the first sync will create it. Saving does not require the test.

Use the same kind and the same address on every device. After that sync needs no attention: a small icon shows the state, and an error does not block work. With WebDAV and a folder the content of attachments moves after the tasks themselves; the icon on macOS and Settings → Sync on both apps show how many attachments still wait, and a file that the storage refuses does not stop the rest. On Android sync also runs in the background every 15 minutes, and a change made on the phone is sent even if the app is closed right after.

A phone that restricts background work puts these runs off. Settings → Sync → Background work shows whether Lists is restricted; tap it to let Lists run without battery restrictions. The app asks once by itself: when sync is turned on, or when it is opened with sync already on. Do the same for the ntfy app if you use it, and on phones that have an "autostart" setting allow it for both.

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

When a device that already has tasks is connected to a storage that has tasks as well, Save and sync on macOS and Android asks which side to keep:

- **Merge** keeps the tasks of both sides. This is what happens without the question, when one of the sides is empty.
- **Use the data of the storage** erases the tasks, lists and filters of this device and reads them again from the storage. Changes that were not synced are lost.
- **Use the data of this device** puts the state of this device over the storage and every other device. What this device does not have goes to the Trash on all devices and can be restored from there; edits made elsewhere are undone. An edit that another device made before and uploads only later is still merged in.

The two replacements ask for a confirmation first; Cancel leaves the settings unsaved. To get the question for a storage that is already connected, turn sync off, save, and connect again. The web server, whose storage comes from the environment, always merges.

Edits are saved locally at once. Two devices that change different fields of one task both keep their change; when they change the same field, the later edit wins. How the two kinds compare is in the [README](../README.md#sync).

## Notifications

Each device has its own notification settings, and they do not sync:

- whether to show notifications at all;
- how long before a timed due date to remind: at the time, from 5 minutes to a day before. Several can be on at once, for example a day before and again 15 minutes before;
- at what time to remind about tasks due on a day;
- an optional summary of the day and its time;
- the sound. On macOS turn it on or off and choose the standard notification sound or one of the system alert sounds; a system sound plays when you choose it. On Android tap "Sound" to open the system settings of the "Reminders" channel and choose the sound there.

A reminder set on a task itself replaces the one derived from its due date. The web interface does not notify.

On Android 13 and newer a notification arrives at its minute only when "Alarms & reminders" is allowed for Lists. Until then the notification settings show "Reminders may come late": tap it and allow. Without it the system may deliver a notification up to an hour late.

## Calendar events in Today

Today can show the events of the day from the calendars of the device, in a muted block above the tasks. It is off until you turn it on, each device has its own setting, and it does not sync:

- macOS: Settings → Tasks → Calendar events → "Show calendar events in Today";
- Android: Settings → Tasks → Calendar events → "Show calendar events in Today".

Turning it on is when the system asks to let Lists read the calendars; nothing is asked before that. The system gives access to all calendars at once. The list under the switch chooses which of them are shown: take the mark off a calendar to leave its events out. A calendar added later is shown until its mark is taken off.

An event is one line: a bar in the colour of its calendar, the start time and the title. All-day events have no time and come first; timed events follow by their start. An event that began before today has no time either. An event that is over stays until the end of the day.

Events are not tasks: they have no mark, cannot be completed, edited or moved, and are not counted in Today or found by search. On Android a tap opens the event in the calendar app. On macOS a click opens Calendar; it cannot be opened on a particular event.

Events are only read, and only on the device. Lists does not store them, change them or send them anywhere: they are not part of sync and never reach the sync server or the web interface. The web interface, Upcoming and the other views show no events.

If access was refused, the settings say so in a line that opens the system settings: Privacy & Security → Calendars on macOS, the permissions of Lists on Android.

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
| Esc in the card of a new task | cancel: close the card without creating the task |
| ⌘Return in the card of a new task | create the task from any field |
| Space or ⌘Enter | complete |
| ⌘T | due today |
| ⌘] and ⌘[ | make a subtask, move a level up |
| ⌘1 … ⌘6 | views |
| ⌘F | search |
| ⌘Z | undo |
| ⌃⌥Space | quick entry from any app |

The settings are in five sections: General (appearance, text, the rows of the sidebar on macOS, completed tasks), Tasks (new tasks, the shortcut of quick entry on macOS, calendar events), Notifications, Sync and Backups. On macOS they are the tabs of the settings window, and the window opens on the tab used last. On Android the settings take the whole screen and start with the list of the sections: a tap opens a section, the arrow at the title or Back returns to the list, and Import… stands under the sections.

Text size (five steps) and typeface (system, rounded, serif, monospaced) are chosen in Settings → General. On Android Settings → General has Text size with the same five steps and no choice of typeface; the step multiplies the font size set in the system, so the system setting keeps working and the step corrects it for Lists alone.

## Light and dark

By default the apps look the way the system does, and follow it when it switches between light and dark on a schedule. Appearance chooses otherwise: Same as the system, Light or Dark. It is in Settings on macOS, in Settings in the drawer on Android, and at the bottom of the sidebar in the web interface. The choice applies at once and to every window, is kept by the device (by the browser in the web interface) and does not sync. List colours and the red of an overdue date are the same in both looks.

## Orientation on Android

On a phone the app stays in portrait and does not turn with the device. The quick-entry window is the exception: it opens over another app and may stand in landscape with it. On a tablet and on an unfolded foldable the app turns with the device.

## Gestures on Android

The title of the view stands large at the top of the list; the menu, search and the sync icon are in the row above it. A long press on Inbox, a list or a filter in the panel with the lists opens its settings. Swipe right to complete, swipe left to set the due date; a swipe to the right that starts at the left edge of the screen opens the panel with the lists instead. Pull down at the top of a list to sync right away; this works once sync is set up. Long-press for the menu: due date, priority, move to list, add subtask, duplicate, won't do, delete.

## Backups

The apps for macOS and Android keep backups of your data on the device. A backup is one file, `.listsbackup`, with the tasks, lists, tags, projects, filters, the trash, the completed tasks and the attachments that are on the device. It does not hold where the device syncs, passwords, or the settings of the device itself.

Settings → Backups:

- **Create backups**: never, every 24 hours (the default) or every 48 hours. A backup is made when the app runs: at start and with the runs of sync.
- **Keep at most**: 5 (the default), 10, 20 or 30. After a new backup the oldest ones over that number are removed.
- **Create backup now** makes one at once. A device that has no tasks and no lists of its own yet makes no automatic backup.
- Each backup in the list can be restored, saved as a copy to a place you choose, or deleted.
- **Restore from file** takes a backup saved elsewhere, for example on another device or after a fresh install.

A new version of the app that changes how the data is stored makes a backup by itself before it touches the data, whatever the schedule says. It is an ordinary backup: it shows in the list and counts towards the number that is kept.

Backups live in the data folder of the app and go away with it, so save a copy elsewhere from time to time.

Restoring replaces everything on the device with what the backup holds; the state before it is saved as one more backup first. With sync on, the app asks what to do with the storage: **merge** keeps what happened since the backup (a later edit wins, and what was deleted since stays deleted), **replace the data of the storage** gives the restored state to the storage and to every other device, where the rest goes to the Trash. The web server has no schedule of backups and no settings for them: back up its data volume, see [self-hosting](self-hosting.md). The one backup it does make is the one before a change of how the data is stored; it lies in `backups` of the data volume and is restored with the app for macOS or Android.

## Import

| Source | File |
|---|---|
| 2Do | backup, `.2dodb` |
| Todoist | CSV template |
| Trello | board exported as JSON |
| Microsoft To Do | lists as JSON |

Import from File → Import… on macOS, from Settings on Android, from the sidebar in the web interface. Importing the same file again updates what is already there. What each importer carries over, and what it cannot, is in [specs/import.md](specs/import.md) (in Russian).
