# Lists: sync over CalDAV

Status: implemented in the core and checked by the tests in `core/tests/caldav.rs` against a test server; of the real servers, the scenarios `real_server_round_trip` and `real_server_calendar_kept_for_a_deleted_list` from the same file pass on Radicale 3.8.2 (2026-10-06); they have not been run against Nextcloud or others. Categories over the limit (C31, #317) are checked by the test `s51_*` in `core/tests/caldav.rs` and by a unit test in `core/src/caldav/map.rs`. Sources: the decision of the author of the project of 2026-10-05 ("as a second transport"), the check of servers and clients in [architecture.md](../architecture.md), RFC 4791, RFC 5545, RFC 6578.

## Purpose and scope

A second way to sync, next to the journal over WebDAV ([sync.md](sync.md)). A device uses one of them. CalDAV is for places where it is the only option, and for cases where the tasks should be visible in other clients.

The merge rules are the same: a register per field, the larger stamp wins (S1–S7 in sync.md). Only where the data lives and how foreign edits are detected changes.

Out of scope: shared calendars with different permissions, invitations, VEVENT, managed attachments (RFC 8607), import of foreign attachments.

## Requirements

### Mapping

- C1. A list is a calendar that supports VTODO. The name and colour of the list are in the standard properties `displayname` and `calendar-color`; the other settings are in a custom property of the collection. If the server does not keep the custom property, these settings stay on the device and are not synced.
- C2. A task is one VTODO; `UID` equals the identifier of the task. A subtask is in the calendar of its top-level ancestor and refers to its parent through `RELATED-TO`. A subtask has only a name and completion (R10 in `product.md`), so its object has none of the other standard properties.
- C3. The name, note, start date, due date, priority, tags, repeat and completion are written to standard properties (`SUMMARY`, `DESCRIPTION`, `DTSTART`, `DUE`, `PRIORITY`, `CATEGORIES`, `RRULE`, `STATUS` with `COMPLETED`; the "Won't do" outcome is C27). Dates are written without a time zone. For a task of a project, `DTSTART` and `DUE` are its own start date and due date: the due date and start date taken from the project (R125 in [product.md](product.md)) are not written.
- C31. A category that does not fit into the field `tag:<name>` under S51 in [sync.md](sync.md) does not become a tag: it is not read from `CATEGORIES` and is not written to them. A tag longer than the limit, left on the device from a version before S51, is not written to `CATEGORIES`.
- C4. The full state of the task — all registers with their stamps, including fields without a standard counterpart and the records of attachments — is in the property `X-LISTS-STATE`.
- C5. An attachment up to 5 MB is written into the VTODO as `ATTACH` in base64, with a parameter carrying its SHA-256. A larger one stays on the device; its record is synced. The attachments of one task take no more than 20 MB of the object in total: they are added in the order of their hashes, and what does not fit also stays on the device with a synced record. The order is the same on every device, so devices do not rewrite the object after each other.
- C6. A task in the Trash is not kept on the server: its object is deleted. Restoring it from the Trash creates the object again. The objects of tasks and repeat records removed by clearing "Completed" (R46) are deleted the same way.

### Foreign clients

- C7. Foreign properties and components of an object are kept on every write: the app changes only the properties from C3–C5.
- C8. If a standard property differs from what is recorded in `X-LISTS-STATE`, it is an edit by a foreign client: it is accepted as the new value of the field.
- C9. An object without `X-LISTS-STATE` is accepted as a task built from the standard properties. If a foreign client stripped the state, the fields without a standard counterpart are taken from the database of the device and returned to the server.
- C10. A task created by a foreign client gets its identifier from its `UID`; a foreign calendar gets an identifier computed from its address, the same on every device.
- C11. When a foreign client marks a repeating task completed, the task moves to its next repeat under the rules of R17 instead of closing.
- C27. A "Won't do" task (R69) is written with `STATUS:CANCELLED` and without `PERCENT-COMPLETE`; the property `COMPLETED` with the moment of closing stays, so that a version of the app that does not know the outcome reads the task as closed instead of returning it to work. When a foreign client sets `STATUS:CANCELLED` on an open task, the task gets the "Won't do" outcome under the rules of R69: a repeating one moves to its next repeat, as in C11. When a foreign client changes `CANCELLED` to `COMPLETED` or back, the outcome changes and the moment of closing stays; when it sets `NEEDS-ACTION` back, the task returns to work. An object with `STATUS:COMPLETED` whose `COMPLETED` equals the moment of closing of a "Won't do" task was written by a version that does not know the outcome: the outcome does not change.
- C12. An `RRULE` that cannot be expressed by the rules R14–R16 is left untouched and does not replace the repeat recorded in the state.

### Exchange

- C13. An existing object is written with `If-Match`, a new one with `If-None-Match: *`. A refusal by the server means the object has changed: it is read again, merged, and the write is repeated.
- C14. An object that has disappeared from the server sends its task to the Trash on the device. An edit made on the device before that stays in the task and is visible after restoring it.
- C15. A list deleted on one device is deleted on the others too: the deletion is recorded in the state of the calendar (C1). The calendar itself is deleted from the server only when no objects are left in it; until then it stays for the sake of the objects of foreign clients, and no device shows it as a list.
- C16. A repeated sync without edits writes nothing to the server.
- C23. An object is read whole if it is no larger than 32 MB. A larger object, and an object that does not parse as iCalendar, does not become a task and is not overwritten; the rest syncs as usual, and the sync status shows an error with the address of the object. While the ETag of the object stays the same, it is not read again, and the error stays after every run. An object that has changed and has been read is accepted as usual.
- C24. A calendar that is gone from a known address means the list is deleted only if no calendar for the list has been found at another address. A calendar with the same list identifier in the last segment of its address is the same calendar after a move: the list, its settings and its tasks stay in place, and nothing is deleted from the server.

### Which side to keep

- C28. The choice of side (S36–S39 in sync.md) applies here too. The server has data when at least one calendar of the collection holds an object; the check goes the same way as C26 and only reads. "Use the data of the server": the device erases its data (S37) and reads the server as if connected for the first time; nothing is written to the server except what an ordinary first run writes. The shared settings (S32) stay on the device: CalDAV does not carry them. "Use the data of this device" (S38): after an ordinary run the device returns its fields to their remembered values, and the next run rewrites the objects of its tasks, deletes the objects of tasks it did not have (C6), and the calendars of lists it did not have once they are empty (C15). Edits and tasks of foreign clients follow the same rule: an edit in a standard property (C8) is undone, a task of a foreign client (C10) goes to the Trash of the device and disappears from the server. Events and other objects that are not tasks of the app (C25) are left untouched. Between the two runs the server holds the merged state, and another client may see it; after the second run it is replaced.

### Checking the settings

- C26. The check of the settings before saving (S26 in sync.md) finds the calendar collection the same way as the first run (C18) and reads the list of calendars in it. The address found is not remembered, and no calendars are created. If the collection is found, the connection works, even if there are no calendars in it yet; if there is no collection, the address is not found; a refusal by the server and a network failure are reported as during sync.

### Push

- C22. The addresses that receive pushes (S18–S21 in sync.md) are in a custom property of the "Inbox" calendar: a table "device → address". A device adds or removes its own row and leaves the others alone. If the server does not keep the property, there are no pushes, and sync runs on the schedule.

### Cost of a run

A run with nothing to transfer costs one request where the server allows it. Each rule below has a fallback, so a server without the needed capability syncs the same way, only at a higher cost.

- C18. The address of the calendar collection is remembered after the first successful run and is looked up again only when the collection is no longer at it. Changing the sync settings resets it.
- C19. A calendar whose change stamp (`getctag`, or `sync-token` without it) is the same as at the last fully read list of its objects is not read. A server without such stamps returns the list of objects on every run. A write by the device itself also changes the stamp, so the calendar is read once more after it. The same applies to the calendar of a deleted list that stays on the server because of foreign objects (C15): while its stamp is the same as when objects were found in it, it is not read and not checked for emptiness. On a server without stamps such a calendar is listed once per run.
- C20. A changed calendar is read with the report `sync-collection` (RFC 6578) from the sync token remembered at the previous read: the server names only the changed and vanished objects. If the server does not know the report, does not accept the token, or the response is incomplete, the full list of objects with their ETags is read.
- C21. The changed objects of one calendar, when there are more than one, are read with the report `calendar-multiget` in batches of 20. An object missing from the response, and any object on a server without this report, is read with a separate `GET`.
- C25. An object that is not a task of the app — an event of a foreign client or a VTODO without a usable `UID` — is remembered by its ETag and is not read again while the ETag stays the same. It does not become a task and is not changed on the server. An object without an ETag cannot be remembered: it is read on every read of the calendar.
- C17. A task whose registers and server object have not changed since the last reconciliation is not rebuilt, and its attachments are not read. A reconciliation is either a write of the object or the conclusion that there is nothing to write.
- C29. A foreign client can give a subtask a due date, start date, priority, categories, repeat or description, and build a chain of `RELATED-TO` deeper than one level. Such an edit is accepted under C8 and, at the end of the run, once all objects have been read, is brought into line with R112: the fields are removed, and a subtask of a subtask gets as its parent the task under which its former parent was. The object goes to the server again, without these properties, on the next run. Nothing is brought into line in the middle of a run: the object of a task of a project can be read before the object of the project. Tasks of a project are not affected.
- C30. Unneeded attachment content (S47 in [sync.md](sync.md)) is deleted from the attachments folder of the device at the end of a run that has gone through to the end, at the same point as the bringing into line under C29. There is nothing to delete on the server: the content is in the object of the task (C5) and goes away with it (C6).

## Known limitations

- Servers that strip unknown `X-` properties (the check points to Cyrus) reduce sync to the standard fields: the order of tasks, reminders and counting a repeat from the completion date are not carried between devices.
- An attachment is transferred again on every write of its task.
- A task with an attachment arrives only together with the attachment's content: the content is in the object itself (C5). CalDAV has no separate pass for content and no download on request (S34, S35 in [sync.md](sync.md)).
- The check of the settings (C26) does not tell a WebDAV server without CalDAV from an empty calendar collection: in both cases the collection responds and has no calendars. The difference shows up at the first sync, when the server refuses to create a calendar.
- Attachments that did not fit into the object (C5) exist only on the devices where they already are: the other devices receive the record without the content. Foreign attachments in the object do not count toward the limit, so together with them the object can exceed 32 MB and become unreadable (C23).
- An object larger than 32 MB, written by the app before the limit appeared, does not shrink on its own: it is rewritten at the next edit of the task on the device that wrote it.
- The servers' own limits on object size have not been checked: a server with a threshold below 28 MB refuses the write, and that is a run error.
- A server that does not keep the custom property of the collection (C1) does not carry the deletion of a list either while the calendar is not empty: on the other devices the list stays empty until the calendar disappears.
- The shared settings of the app (S32 in [sync.md](sync.md)) are not carried over CalDAV: the time a completed task stays in a view (R68 in [product.md](product.md)) is set on each device.
- A foreign calendar becomes a new list after a move: its identifier is computed from the full address (C10), so a move cannot be told from one calendar being deleted and another appearing. The tasks move to a new list with the same name, and the old one is deleted.
- The Trash is not shared: a task deleted on one device goes to the Trash on the others too, but each device empties its Trash on its own. For the same reason, what is cleared from "Completed" on one device ends up in the Trash on the others instead of disappearing.

## Test scenarios

The tests are in `core/tests/caldav.rs`, the server in `core/tests/common/dav.rs`. The tests `real_server_round_trip` and `real_server_calendar_kept_for_a_deleted_list` repeat the exchange on a real server; they are run by hand and take the address from `LISTS_CALDAV_URL`. The second one plays a foreign client through `curl`; the cost of a run is shown by the request log of the server itself.

- C2–C4: a task with a subtask, due date, priority, tags and repeat → the server has two VTODOs with standard properties and state → the second device gets the same tasks.
- C31: a foreign client puts a 196-byte category and a 197-byte category into `CATEGORIES` → the first becomes a tag, the second is written neither to the fields of the device nor to `CATEGORIES`; a 197-byte tag left in the fields of the device by an earlier version is not written to `CATEGORIES`.
- C29: a foreign client sets `DUE` and `PRIORITY` on the object of a subtask → after sync the subtask on the device has no due date and no priority, and the object on the server has none of these properties. A foreign client creates an object with `RELATED-TO` pointing at a subtask → on the device it is a subtask of the same task as that subtask, and `RELATED-TO` in its object points at that task.
- S2 over CalDAV: two devices change different fields of one task → both devices have both edits.
- C7: a foreign property `X-OTHER` is added to an object → after the task is edited on a device, the property is still there.
- C8: a foreign client changes `SUMMARY` and `DUE` → the device accepts both values, the other fields are untouched.
- C9: a foreign client removes `X-LISTS-STATE` → after sync the state is on the server again, and the fields without a standard counterpart are intact.
- C10: a VTODO without state, created by a foreign client → the task appears on both devices under one identifier.
- C11: a foreign client sets `STATUS:COMPLETED` on a repeating task → the due date is moved, the task is open.
- C27: a "Won't do" task → the object has `STATUS:CANCELLED` and `COMPLETED`, and no `PERCENT-COMPLETE` property; the second device gets it with the same outcome. A foreign client sets `STATUS:CANCELLED` on an open task → on the device it is "Won't do"; on a repeating one → the due date is moved, the task is open, and the history has a "Won't do" entry; it changes `CANCELLED` to `NEEDS-ACTION` → the task is open; it changes `CANCELLED` to `COMPLETED` with a new time → the task is completed; it sets `STATUS:COMPLETED` without touching `COMPLETED` → the task stays "Won't do".
- C13: two devices change one task before sync → the second one gets a refusal, merges and writes; both end with the same result.
- C6, C14: a deletion on a device removes the object; an object disappearing from the server sends its task to the Trash on the second device.
- C6, R46: clearing "Completed" on a device removes the objects of the completed task, its subtask and its repeat records; on the second device they end up in the Trash and are not returned to the server.
- C5: an attachment reaches the second device with the same hash.
- C5: four attachments of 5 MB each all arrive; of seven attachments of 4.9 MB each, four are in the object, the task and all seven records arrive on the second device, neither device writes the object again, and an edit on the second device leaves the same four in the object.
- C23: a foreign object of 33 MB → an error with its address, the other tasks of the calendar arrive, the next run does not read the object, the error stays in the status, own edits reach the server; the object is made smaller → it becomes a task, and there is no error.
- C23: the object of a known task has grown to 33 MB, the task is changed on the device → the object is not overwritten; the object is made smaller → both edits converge.
- C28: the server has task "a" of device A and a task of a foreign client without state, C has task "c" → the check answers "data on both sides"; a server without objects → "no". C uses the data of the server → C has "a" and the foreign task, and "c" is neither on C nor on the server. C has chosen "until the end of the day" for completed tasks → after C has used the data of the server, the choice is the same. C sends its own data → the server has the object of "c" and no objects of "a" or of the foreign task; on A after sync "c" is in place, "a" and the foreign task are in the Trash; the foreign event in the same calendar is in place. A foreign client has changed `SUMMARY` of a task that C has, and C sends its own data → the object has the name from C.
- C16: a second sync in a row makes no writes.
- C18: the address is found through `calendar-home-set` → the next runs do not ask for it; the collection has moved → the address is found again, the data is the same.
- C24: the calendar collection has moved → on both devices the list with its settings and its task is in place, "Inbox" is empty, the object is in the calendar at the new address, the next run writes nothing; a foreign calendar after a move → one list with the same name and the same task.
- C19: a run without edits is one request; an edit by a foreign client in one calendar → only that calendar is read, the tasks of the other calendars stay in place; a server without stamps → the list of every calendar on every run, the same result.
- C15: a list is deleted on one device, and a foreign event is left in its calendar → the list is gone on both devices, its task is in the Trash, the calendar is in place, a run without edits on the second device is one request; the event is removed by a foreign client → the calendar is deleted by whichever device syncs first.
- C15, C19: a list is deleted, and a foreign event is left in its calendar → the calendar is in place, a run without edits is one request, including after sync is turned off and on again; a server without stamps → one listing of this calendar per run; the event is removed by a foreign client → the calendar is deleted.
- C25: a server without stamps, two foreign events in the calendar of a list → a run without edits makes no `GET`; an event is changed → one `GET`, the next run again without them, no error in the status; an event disappears → the tasks are in place; a task is written at the address of an event → it appears in the list.
- C20: an edit and a deletion by a foreign client arrive through `sync-collection` without the full list; a token that the server has forgotten → the full list, the same result.
- C21: the first read of a calendar with several tasks is one `calendar-multiget` and no `GET`; a server without reports → one `GET` per object, the same result.
- C22 (in `core/tests/push.rs`): the same as S18–S20, over CalDAV; a server without custom properties → no pushes, and the property is not rewritten on every run.
- C26: the right password → the connection works, only `PROPFIND` requests went to the server, and no calendars appeared; the collection is named through `calendar-home-set` → the connection works; a wrong password → an error with 401; no collection → the address is not found.
- C30: on A a task with an attachment is deleted for good, another is in the Trash → after the run A has no content of the first and still has the content of the second. The Trash is not shared (a known limitation), so on B both tasks are in the Trash and the content of both is in place; after the Trash is emptied on B, the content is gone.
- C17: a sync without edits rebuilds no tasks; an edit of one task on a device or by a foreign client rebuilds only that task; a subtask moves to another calendar after its parent.
