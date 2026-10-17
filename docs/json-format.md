# The JSON format of Lists

Lists exports its data as one JSON file (R155 in [specs/product.md](specs/product.md)) and imports the same file back (I11 in [specs/import.md](specs/import.md)). The format is meant for leaving Lists, for scripts and for moving data from other programs: write a file in this shape and import it.

## The file

```json
{
  "format": "lists",
  "version": 1,
  "exported": "2026-10-17T20:15",
  "lists": [ … ],
  "tasks": [ … ],
  "filters": [ … ]
}
```

- `format` is always `"lists"`: this is how the importer recognises the file.
- `version` is 1. A later version changes it only when an earlier reader would misread a file; an importer refuses a version newer than its own.
- `exported` is the local time of the export, `YYYY-MM-DDTHH:MM`. The importer ignores it.

Dates are local time throughout: `YYYY-MM-DD` for a day, `YYYY-MM-DDTHH:MM` for a day with a time.

## Lists

```json
{
  "id": "0199f2c4-…",
  "name": "Home",
  "color": "#379417",
  "icon": "",
  "archived": false,
  "sort": "due",
  "showDone": false,
  "defaultPriority": "none",
  "defaultDueToday": false
}
```

| Field | Meaning |
|---|---|
| `id` | any string unique in the file; tasks and filters refer to it. `"inbox"` is the Inbox |
| `name` | the name; the Inbox has an empty one |
| `color` | `#RRGGBB`, or empty for the default |
| `icon` | an icon name, or empty |
| `archived` | an archived list is hidden from the sidebar |
| `sort` | `manual`, `due`, `priority` or `title` |
| `showDone` | completed tasks stay in the list |
| `defaultPriority`, `defaultDueToday` | what a new task in this list gets |

The importer puts the tasks of `"inbox"` into the Inbox of the device and does not create a list for it.

## Tasks

```json
{
  "id": "0199f2c5-…",
  "list": "0199f2c4-…",
  "parent": null,
  "title": "Buy paint",
  "notes": "white\ntwo cans",
  "start": "2026-10-06",
  "due": "2026-10-07T18:30",
  "remind": "2026-10-07T18:00",
  "priority": "high",
  "tags": ["home"],
  "repeat": null,
  "done": null,
  "wontDo": false,
  "project": false,
  "attachments": [{ "name": "photo.jpg", "mime": "image/jpeg", "size": 48213, "sha256": "…" }]
}
```

| Field | Meaning |
|---|---|
| `id` | any string unique in the file |
| `list` | the `id` of a list |
| `parent` | the `id` of the task above: a project (the task is in the project) or a task (the task is its subtask); `null` at the top |
| `title`, `notes` | the notes are Markdown |
| `start`, `due`, `remind` | dates as above, or `null` |
| `priority` | `none`, `low`, `medium` or `high` |
| `tags` | names without `#` |
| `repeat` | a rule (below) or `null` |
| `done` | when the task was completed, or `null` while it is open |
| `wontDo` | with `done` set: the task was closed as "won't do" |
| `project` | a top-level task that is a project |
| `attachments` | the files of the task: name, type, size in bytes and SHA-256 of the content. The content itself is not in the file |

Tasks come in the order of their lists, parents before their subtasks. The importer keeps that order. A subtask has a title and a completion and nothing else (R10): the importer drops its other fields. The trash is not exported. A record of a finished repeat is exported as a completed task.

### Repeat

```json
{ "freq": "weekly", "interval": 2, "weekdays": [1, 4], "from_done": false, "count": 5 }
```

| Field | Meaning |
|---|---|
| `freq` | `daily`, `weekly`, `monthly` or `yearly` |
| `interval` | every that many periods, 1 or more |
| `weekdays` | weekly: the days, 1 (Monday) to 7 (Sunday); missing means the weekday of the due date |
| `monthday` | monthly: the day of the month; 31 means the last day in shorter months |
| `nth`, `nth_weekday` | monthly: the n-th (1 to 5, or -1 for the last) given weekday |
| `from_done` | the next date counts from the completion, not from the due date |
| `count` | occurrences left, the current one included |
| `until` | the last allowed date, `YYYY-MM-DD` |

## Saved filters

```json
{ "id": "0199f2c6-…", "name": "Urgent", "spec": { "due": { "kind": "any" }, "list_ids": ["0199f2c4-…"], "min_priority": "high", "status": "open" } }
```

| Field of `spec` | Meaning |
|---|---|
| `due` | `{"kind": "any"}`, `"overdue"`, `"today"`, `"nodate"`, or `{"kind": "next", "days": 7}` |
| `list_ids` | the `id`s of lists; empty or missing means any list |
| `tags` | the task carries all of these |
| `min_priority` | `none`, `low`, `medium` or `high` |
| `status` | `open`, `done`, `wont` or `all` |
| `text` | words the title or the notes contain |

Filters are exported only with everything, not with one list.

## Importing

- A second import of the same file updates what the first one brought instead of adding copies. The importer derives its ids from the ids in the file.
- Importing an export into the device it came from therefore makes copies of the tasks; it does not write over the originals.
- Attachments are listed but not carried: the report says how many were left out.
