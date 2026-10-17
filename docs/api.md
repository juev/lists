# HTTP API of the web server

The web interface talks to `lists-web` over a small JSON API. Scripts, Shortcuts, Tasker or Raycast can use the same API with an API token. This page describes what a token reaches. The rules are R150–R152 in [specs/product.md](specs/product.md).

## Tokens

Make a token in the web interface: "API tokens…" in the side panel, a name, and a scope.

- **Read** allows `GET` and `HEAD` requests only.
- **Read and write** allows every request below.

The token is shown once. Copy it then: the server keeps only its SHA-256 and cannot show it again. Revoke a token in the same list. A revoked token gets 401 at once.

Send the token in the `Authorization` header:

```sh
curl -H "Authorization: Bearer lists_…" https://lists.example.org/api/overview
```

A request with a token needs no cookie and no `X-Lists` header. No token can make or revoke tokens, sign out or subscribe to notifications: those need a session of the web interface, and the server answers 403.

Each token has its own undo history: `undo` with a token takes back the last action of that token.

## Limits

- One token makes at most 600 requests a minute. Beyond that the server answers 429 with `Retry-After` in seconds.
- A wrong or revoked token counts as a failed login. After five within a minute the client gets 429, for passwords as well (R134).
- Request bodies are limited to 64 MB, and attachments to the limits of `LISTS_MAX_FILE_MB` and `LISTS_MAX_TASK_MB`.

## Time zone

"Today", "Upcoming" and dates typed without a day are read on the clock of the request. Send your offset from UTC in minutes as `X-Lists-Zone`, for example `180` for Moscow. Without it the server uses its own zone, which is UTC in the Docker image (R135).

## Reading

| Request | Answer |
|---|---|
| `GET /api/overview` | counts of the views, the lists, projects, filters, tags and the sync state |
| `GET /api/tasks?scope=<scope>` | the tasks of a view, as shown in the page |
| `GET /api/task?id=<id>` | one task with its subtasks and attachments, and its notes laid out from Markdown |
| `GET /api/file?task=<task id>&id=<attachment id>` | the content of an attachment; `Range` is supported |

A scope is one of `inbox`, `today`, `upcoming`, `all`, `completed`, `wontdo`, `trash`, or `list:<id>`, `project:<id>`, `filter:<id>`, `tag:<name>`, `search:<text>`. Put it in the address percent-encoded.

A task comes as an object with `id`, `list`, `parent`, `title`, `notes`, `start`, `due`, `effectiveStart`, `effectiveDue`, `priority` (0 none, 1 low, 2 medium, 3 high), `tags`, `repeat`, `remind`, `done`, `wont`, `deleted`, `project`, `subtasks`, `subtasksDone` and `attachments`. Dates are `YYYY-MM-DD`, or `YYYY-MM-DDTHH:MM` with a time of day, in local time.

## Changing

Almost every change is `POST /api/call` with a JSON body that names the operation in `op`:

```sh
curl -X POST https://lists.example.org/api/call \
  -H "Authorization: Bearer lists_…" -H "X-Lists-Zone: 180" \
  -H "Content-Type: application/json" \
  -d '{"op": "quickAdd", "text": "Buy bread tomorrow 18:00 !! #home", "scope": "inbox"}'
```

| `op` | Arguments | Does |
|---|---|---|
| `quickAdd` | `text`, `scope` | adds a task the way quick entry does: the date, the time, the priority (`!` to `!!!`), the tags (`#home`) and the list (`@Shopping`) are read from the text; `scope` gives the list (`list:<id>`, `inbox`) or the project (`project:<id>`) |
| `addSubtask` | `parent`, `title` | adds a subtask |
| `setTitle`, `setNotes` | `id`, `value` | |
| `setStart`, `setDue`, `setRemind` | `id`, `value` | a date, a date with a time, or `null` to clear |
| `setPriority` | `id`, `value` | 0–3 |
| `setRepeat` | `id`, `value` | a rule such as `{"freq": "weekly", "interval": 1}`, or `null` |
| `addTag`, `removeTag` | `id`, `value` | |
| `complete`, `wontDo`, `reopen` | `id` | |
| `delete`, `restore` | `id` | moves to the trash and back |
| `moveToList`, `moveToProject` | `id`, `list` or `project` | |
| `duplicate` | `id` | |
| `undo` | | takes back the last action of this token |
| `createList` | `name` | |
| `createProject` | `title`, `scope` | |
| `sync` | | syncs now and answers with the numbers of changes pulled and pushed |

An attachment is added with `POST /api/upload?task=<task id>&name=<file name>` and the file as the body. `removeAttachment` with the attachment `id` removes one.

## Errors

An error comes as `{"error": "…"}` with the status:

- 400: the request is not understood;
- 401: no session and no valid token;
- 403: the token may not do this;
- 404: nothing with that id;
- 413: a file above the limit;
- 429: too many requests;
- 502: the storage failed during `sync`.
