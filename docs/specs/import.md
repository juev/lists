# Lists: import from other task managers

Status: implemented in the core (`core/src/import.rs`), checked by the tests in `core/tests/import.rs`; the 2Do import has also been run on a real backup of 2Do 4.19 for macOS. Sources: the request of the author of the project of 2026-10-05; an analysis of a real backup; three real TickTick backups from public repositories (#350); the real Things 3.24.1 database of the author of the project (#351); a real OmniFocus 2 export from a public repository and two independent descriptions of the OmniFocus 3 and 4 export (#352); the documentation of Todoist, Trello and Microsoft Graph (links below).

## Purpose and scope

Move data from another manager with a single file. The format is detected from the content. Importing the same file again updates what was already imported and creates no duplicates: identifiers are derived from the identifiers of the source.

The entry point is the "File → Import…" menu on macOS, the settings on Android, and the sidebar of the web interface.

## Requirements

- I1. **2Do**, a `.2dodb` file ("Save a Copy…" or the automatic copies in `~/Library/Containers/com.guidedways.TodoMac/Data/Library/Application Support/Backups`). It is a zip with the SQLite database `2do.db` and a folder of attachments. Imported: regular lists with their colour; tasks with title, note, due date (with time), start date, priority, tags, completion, nesting, the project flag, link and attachment files.
- I2. The repeat rule of 2Do is imported in full: "every N days, weeks, months, years" (the ready-made 2Do options are stored this way too), weekly on chosen days, "the n-th or last weekday of the month", counting from the completion date, ending on a date and after a number of repeats. A task with a repeat code outside the table below gets the tag `2do-repeat`, and the report gives the number of such tasks.
- I3. **Todoist**, the CSV template of a project. The file name becomes the name of the list. Imported: tasks with nesting (`INDENT`), description, comments (into the note), priority, `@label` labels and date. A date or repeat written in words and not recognised is added to the note as is.
- I4. **Trello**, the JSON of a board. Columns become lists "Board: column", cards become tasks, checklist items become subtasks, labels become tags. Archived cards and columns are skipped.
- I5. **Microsoft To Do**, lists with tasks as JSON, the way Microsoft Graph returns them (`todoTaskList` with nested `tasks`). The app has no export of its own; such a file is produced, for example, by the Microsoft-To-Do-Export utility. Imported: title, note, due date, start, reminder, importance, categories, completion, steps and repeats, except "relative" ones ("the second Tuesday of the month").
- I6. After the import the user sees a report: how many lists, tasks and attachments were imported and what could not be imported.
- I7. A file of an unknown format is rejected with an explanation and changes nothing.
- I8. **2Do, attachment name.** 2Do stores the name of an attachment and its extension separately: a photo is recorded as "Image" with the extension "jpg" beside it. The attachment gets a name with the extension: "Image.jpg". A name that already ends with this extension is not changed; an attachment without a name is called "attachment" with the extension.
- I9. The import follows the rule on subtasks (R10 and R112 in `product.md`): a subtask keeps its title and completion, its other fields and attachments are not imported; nesting deeper than one level is lifted, and a subtask of a subtask is placed right after its former parent. Tasks of a 2Do project stay full tasks.
- I10. A tag that does not fit into the field `tag:<name>` under S51 in [sync.md](sync.md) is not imported; the report gives the number of such tags.
- I11. **Lists**, the R155 export JSON (`"format": "lists"`, [json-format.md](../json-format.md)) (#349). Everything it contains is imported: lists with colour, icon, sorting, display of completed tasks, defaults for new tasks and archive; tasks with all fields, "Won't do" and the project flag; saved filters, in which the lists are replaced by the imported ones. Tasks of the "Inbox" go to the "Inbox" of the device (R121 applies). The file holds no attachment content: the report gives the number of attachments that were not imported. A file of a newer version of the format is rejected (I7) with a request to update the app. As with other sources, identifiers are derived from the identifiers in the file, so importing an export creates copies of the tasks rather than overwriting those the export was taken from.
- I12. **TickTick**, the backup CSV (Settings → Account → Generate backup) (#350). The format is recognised by the header row with the columns `Folder Name`, `List Name` and `Title`. Each TickTick list becomes a list; a list inside a folder is named "Folder: list", like a Trello board column in I4; tasks of the `Inbox` list without a folder go to the "Inbox" (R121 applies). Imported: title, note, start and due date with or without time, the first reminder, priority, tags, completion and "Won't do", repeat, nesting (`parentId`) and checklist items as subtasks. The order of tasks within a list and within a parent follows the `Order` column. A repeat that the repeat model of Lists cannot express is added to the note as the text of the rule. The report gives the number of reminders beyond the first, repeats left as text, note records (type `NOTE`, imported as tasks) and board lists whose columns are not imported.
- I13. **Things 3**, the SQLite database (#351). Things has no export file: in "File → Import…" the user chooses the `main.sqlite` file or the `Things Database.thingsdatabase` folder, either the working one (`~/Library/Group Containers/JLMPQHK86H.com.culturedcode.ThingsMac/ThingsData-…/Things Database.thingsdatabase`) or one of the copies Things itself places next to it in `Backups`. macOS grants access to another app's container on an explicit choice in the panel; no separate permission is needed. The file is copied to a temporary folder together with the `main.sqlite-wal` journal and read from the copy, so a running Things does not interfere and nothing in its database changes. The format is recognised by the `TMTask` table. Areas become lists; projects become project tasks (R30) in the list of their area, and their tasks become tasks of the project; tasks and projects outside an area, including the Things "Inbox", go to the "Inbox" (R121 applies). Imported: title, note, the "When" date (as the start date), the reminder on that day, due date, tags, completion and cancellation (as "Won't do"), checklist items (as subtasks) and repeat. "Someday" tasks get the tag `someday`. Project headings are not imported; their tasks stay in the project. What was moved to the trash is not imported. A repeating Things task is a template and the tasks it generates: the rule of the template goes to the open generated task, and if there is none, to the template itself with the date of the next repeat; completed generated tasks are imported as completed. A paused repeat is not imported. A rule that the repeat model of Lists cannot express is added to the note. The report gives the number of "Someday" tasks, headings, tasks from the trash, paused repeats and rules left as text, and, if the database version differs from the checked one (29), its number as well.
- I14. **OmniFocus**, CSV (File → Export…, CSV format) (#352). The format is recognised by the header row with the columns `Task ID`, `Type` and `Name`. As in I3, the file name becomes the name of the list. OmniFocus projects become project tasks (R30) of this list, actions become tasks of their project, actions inside an action group become subtasks of the group (I9 applies). Actions of the "Inbox" (`Type` = `Inbox`) go to the "Inbox" (R121 applies). Imported: title, note, start date (`Start Date`), due date (`Due Date`), tags (`Tags`, and in the OmniFocus 2 export `Context`), completion (`Completion Date` or the status `done`), dropped (`dropped`) as "Won't do", the flag as high priority. The report gives the number of tasks with an estimated duration (`Duration`) and with a planned date (`Planned Date`): Lists has no such fields. The export has no repeats, folders or attachments, and the report says so too. `Task ID` is a position in the hierarchy, not a permanent identifier: importing the same export again duplicates nothing, but an export taken after rearranging in OmniFocus matches tasks by their new positions.

## What is known about the formats

2Do, from the database of version 4.19 for macOS. The encoding was established by experiment on 2026-10-05: through the 2Do programming interface (the AppleScript commands `create_task`, `query_tasks`) 37 test tasks with known properties were created, their values were read from the database, and then the tasks were deleted. Eight repeating tasks of the author were also compared with what the app itself reports about them.

- Lists are the `calendars` table. Regular lists have `listtype = 0`, the "Inbox" has `isinboxcal = 1`, other values of `listtype` are internal views; smart lists differ by a non-empty `smartsearch`; the colour is `colorhex`.
- Tasks are the `tasks` table; `parent` is the `uid` of the parent.
- Due date: `duedate` is Unix seconds, noon UTC of the day; a value of about 6.4 billion means "no date". The due time is a separate field `duetime`, a number of the form HHMM (930 is 09:30), 999999 means "no time".
- Start: `startdate` is Unix seconds whose UTC fields equal the local date and time; midnight means "no time".
- Priority on the iCalendar scale: 1 is high, 5 medium, 9 low, 10 none.
- `tasktype`: 0 is a task, 1 a checklist, 2 a project. A checklist is imported as a regular task with subtasks.
- Tags are the `tags` field: eight values per tag joined by the separator `_~|$$@$$|~_`, the first is the name. Checked on tasks with one tag; several tags on one task did not occur.
- Attachments are the `taskattachments` table; the file is at `2DoBackupPayload/Attachments/<relativepath>`.
- Repeat:

| `repeattype` | `repeatvalue` | Rule |
|---|---|---|
| 1–127 | 1 | weekly on days: sum of bits Sun 1, Sat 2, Fri 4, Thu 8, Wed 16, Tue 32, Mon 64 |
| 256 | N | every N days ("every day" is N = 1) |
| 257 | N | every N weeks |
| 258 | N | every N months |
| 259 | N | every N years |
| 260–266 | 1–5 or 6 | the n-th (6 is the last) weekday of every month; 260 is Monday … 266 is Sunday |

  `recurrence` = 2 counts from the completion date (1 from the due date). `recurrenceendtype`: 1 means until the date `recurrenceenddate`, 2 means `recurrenceendrepeats` repeats remain.

Not checked: `repeatvalue` greater than 1 for a weekly rule on days (taken as an interval in weeks; the 2Do interface did not allow creating such a combination), several tags on a task, the 2Do backup formats for Android (`.2dobackup`, `.2dobundle`).

TickTick, from three real backups of versions 7.1 (two, 2024) and 7.2 (2026) from public repositories on GitHub; 831 tasks. An anonymised sample of their rows is `core/tests/data/ticktick-backup.csv`: the internal columns are taken as is, titles, notes, tags, lists and folders are replaced.

- The file is UTF-8, sometimes with a BOM. Before the header there are three quoted lines: `"Date: 2024-05-18+0000"`, `"Version: 7.1"` and a multi-line `"Status: …"`. The header of version 7.1: `Folder Name`, `List Name`, `Title`, `Kind`, `Tags`, `Content`, `Is Check list`, `Start Date`, `Due Date`, `Reminder`, `Repeat`, `Priority`, `Status`, `Created Time`, `Completed Time`, `Order`, `Timezone`, `Is All Day`, `Is Floating`, `Column Name`, `Column Order`, `View Mode`, `taskId`, `parentId`; version 7.2 adds `projectKind` (`TASK` or `NOTE`). Columns are found by name, not by position. Rows of the file are separated by LF, and a line break inside a field (a note, checklist items, several reminders) is a single CR.
- `Status`: 0 is open, 2 completed, -1 "Won't do"; for 2 and -1 `Completed Time` is filled. The legend in the file header ("1 Completed, 2 Archived") disagrees with the data: 1 never occurred, and all 594 tasks with 2 have a completion time.
- `Priority`: 0 is none, 1 low, 3 medium, 5 high. 0, 3 and 5 occurred; the value 1 is taken from the scale, not from the file.
- `Kind`: `TEXT` is a task, `CHECKLIST` a task with a checklist (`Is Check list` = `Y`), `NOTE` a record of a notes list. Checklist items are stored in `Content` line by line: `▫` at the start of a line is an open item, `▪` a checked one.
- Dates are UTC instants of the form `2024-10-15T13:00:00+0000`. For a task without time (`Is All Day` = `true`) the instant is midnight of the day in the time zone from `Timezone`: 16:00 UTC the day before for `Australia/Perth`, 18:30 UTC the day before for `Asia/Kolkata`. The core has no time zone database, so the day is taken by offset: an instant with a UTC hour of 11 or later belongs to the next day. The rule is correct for time zones from −10:00 (Hawaii) to +13:00 (Tonga, New Zealand in summer) and is off by a day for −11:00 (Niue, American Samoa), +13:45 (the Chatham Islands in summer) and +14:00 (the Line Islands). The time of a task with time is converted to the time zone of the device.
- `Start Date` and `Due Date` are equal for a task with one date; for a task with a duration the start is earlier than the due date. Tasks with only one of the two dates did not occur.
- `Reminder`: ISO 8601 offsets in the TRIGGER syntax of RFC 5545 (`PT0S`, `-PT30M`, `-P0DT2H0M0S`, `P0DT9H30M0S`), several separated by a line break. The offset counts from the start of the task, and for a task without time from midnight of its day. The anchoring to the start rather than to the due date is taken from RFC 5545 (the default is `RELATED=START`) and is not checked in TickTick itself: for tasks with a duration in the sample, reminders were set only 0 and 30 minutes before.
- `Repeat` is an RRULE without the prefix: `FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR`, `FREQ=MONTHLY;INTERVAL=1`. Counting from the completion date is not recorded in the file.
- `parentId` is the `taskId` of the parent in the same file; nesting deeper than one level did not occur.
- `Order` is a signed integer of up to 19 digits; TickTick shows tasks in ascending order.

Not checked on real data: priority 1, deleted tasks (the sample has none; whether they go to the trash in a backup is unknown), `Is Floating` = `true`, repeats with parts beyond RFC 5545.

Things 3, from the database of version 29 (`databaseVersion` in the `Meta` table) of the Things 3.24.1 app for macOS, 9174 records. The encoding of dates and statuses was compared on 2026-10-18 with what Things itself reports: through AppleScript (`activation date`, `due date`, `status`) 11 tasks were read, and the values matched the decoding below. The repeat rules were compared with the dates of 1547 tasks generated by 13 templates. An anonymised sample is `core/tests/data/things.sqlite`: the schema and internal fields are as in the real database, titles, notes, areas, tags and checklist items are replaced.

- Tables: `TMArea` (areas), `TMTask` (tasks, projects and headings), `TMChecklistItem`, `TMTag` and the link table `TMTaskTag`.
- `TMTask.type`: 0 is a task, 1 a project, 2 a heading. `status`: 0 is open, 2 cancelled, 3 completed; the moment of completion or cancellation is `stopDate`, Unix seconds. `trashed` = 1 means in the trash. `start`: 0 is "Inbox", 1 "Anytime" or a date, 2 "Someday".
- Links: `area` is the area, `project` the project, `heading` the heading; for a task under a heading the project is taken from the heading.
- The dates `startDate` ("When") and `deadline` (due date) are integers: `year << 16 | month << 12 | day << 7`; 132818432 is 2026-10-12. The year 4001 means "no date".
- `reminderTime` is the time of the reminder on the day of `startDate`: `hour << 26 | minute << 20` (568328192 is 08:30).
- `notes` is plain text.
- Repeat: the template has `rt1_recurrenceRule`, a plist with the keys `fu` (unit: 16 is day, 256 week, 8 month, 4 year), `fa` (interval), `of` (offsets: `wd` is the weekday, 0 is Sunday; `dy` the day of the month counting from zero; `mo` the month counting from zero), `tp` (1 means from the completion date), `ed` (end date, Unix seconds; 64092211200 means "never"), `rc` and `ts`. Generated tasks refer to the template through `rt1_repeatingTemplate`; `rt1_instanceCreationPaused` = 1 means the repeat is paused, `rt1_nextInstanceStartDate` is the date of the next task.

Not checked: `rc` and `ts` (the database has only `rc` = 0 and one paused template with `ts` = -2, so a rule with a non-zero `ts` or `rc` is imported as text), `ed` with a real end date (imported as "until date"), several weekdays in one rule (imported as a set of days), "last day of the month" and "n-th weekday of the month" (did not occur in the database, imported as text), database versions other than 29.

OmniFocus. There is one real export: OmniFocus 2 for macOS, 355 rows, from 2018, published in a public repository on GitHub. The columns of OmniFocus 3 and 4 are taken from two independent descriptions: the test files of the omnifocus_parser parser (2022) and the table in the README of omnifocus-to-todoist-migrator (2025); these files themselves are not exports. The Omni Group has no official description of the format. An anonymised sample of the real export is `core/tests/data/OmniFocus.csv`: identifiers, types, statuses, dates, duration and flags are taken as is, names, projects, contexts and notes are replaced.

- The file is UTF-8 without a BOM, rows are separated by CRLF, a line break inside a note is LF.
- The OmniFocus 2 header: `Task ID`, `Type`, `Name`, `Status`, `Project`, `Context`, `Start Date`, `Due Date`, `Completion Date`, `Duration`, `Flagged`, `Notes`. According to the descriptions, OmniFocus 3 adds the column `Tags` (comma-separated tags), and OmniFocus 4 adds `Planned Date`. Columns are found by name.
- `Task ID` is a path in the hierarchy: `1` is a project, `1.3` its action, `1.3.2` an action inside the group `1.3`. Nesting of up to five levels occurred (`10.1.1.3.1`).
- `Type`: `Project` or `Action`; according to the 2025 description there is also `Inbox`. In the real export every action has `Project` filled.
- `Status` is filled only for projects: `active` or `done`. The value `dropped` and statuses of actions did not occur in the sample; a completed action is recognised by `Completion Date`.
- Dates are instants of the form `2018-11-20 12:00:00 +0000`; the time is always present and is converted to the time zone of the device.
- `Duration` is an estimate of the form `60m`, `30m`. `Flagged` is `0` or `1`; the real export has only `0`.
- The export has no repeats, folders, attachments or order of projects in folders.

Not checked on real data: OmniFocus 3 and 4 exports, the type `Inbox`, the status `dropped`, the flag `1`, the column `Planned Date`.

Todoist, Trello and Microsoft To Do are implemented from the documentation and have not been run on real exports:

- <https://www.todoist.com/help/articles/import-or-export-a-project-as-a-csv-file-in-todoist-YC8YvN>
- <https://developer.atlassian.com/cloud/trello/guides/rest-api/object-definitions/>
- <https://learn.microsoft.com/en-us/graph/api/resources/todotask?view=graph-rest-1.0>, <https://github.com/daylamtayari/Microsoft-To-Do-Export>

## Test scenarios

`core/tests/import.rs`:

- I11: `r155_i11_an_export_imported_into_an_empty_device_gives_the_same_data_and_a_second_import_changes_nothing` and `r155_one_list_and_a_newer_version_of_the_format`.
- I1, I2: `twodo_backup_brings_lists_tasks_subtasks_tags_and_attachments` — a database with the schema of a real backup; the unit tests `twodo_repeat_codes` and `twodo_dates` in `core/src/import.rs` repeat the values written by 2Do itself; internal, smart and deleted lists are not imported; an attachment path that leads outside the backup is ignored; importing again creates no duplicates.
- I8: `i8_twodo_attachment_gets_the_extension_kept_beside_its_name` — the attachment "Image" with the extension "jpg" becomes "Image.jpg" with the JPEG type, "План.jpg" stays as is.
- I3: `todoist_csv_template`. I4: `trello_board_json`. I5: `microsoft_to_do_lists_json`. I7: `unknown_files_are_refused_with_a_reason`.
- I12: `i12_ticktick_backup_brings_lists_dates_reminders_checklists_and_subtasks` — on `core/tests/data/ticktick-backup.csv`; the unit test `ticktick_dates_and_reminders` in `core/src/import.rs`.
- I13: `i13_things_database_brings_areas_projects_dates_checklists_and_repeats` — on `core/tests/data/things.sqlite`; the unit test `things_dates_and_repeat_rules` in `core/src/import.rs` on the rules of all 13 templates of the real database.
- I14: `i14_omnifocus_export_brings_projects_actions_groups_dates_and_completion` — on `core/tests/data/OmniFocus.csv`; `i14_omnifocus_3_and_4_columns_inbox_dropped_and_flagged` — from the descriptions of the newer versions.
- I10: `i10_a_tag_that_does_not_fit_a_register_is_not_imported` — a label of 196 bytes is imported, one of 197 bytes is skipped, the report gives one skipped tag.
