# Lists: design decisions

Status: decisions made on 2026-10-05; the apps for macOS and Android and the web server are released (release candidates 0.1.0). Sources: the request of the author of the project, the 2Do documentation, RFC 5545/6578/8607, the documentation of UniFFI, Kotlin Multiplatform, Flutter and Tauri, write-ups of Actual Budget and "Local, first, forever" (links at the end).

## Name

**Lists.** Chosen by the author of the project on 2026-10-05 instead of the first option, "Galka", which seemed too colloquial. The name describes the content literally and needs no explanation. A known clash is Microsoft Lists; publishing in the app stores is not planned, so the clash is accepted.

Considered: Jackdaw, Otmetka, Marque (free in the App Store and on GitHub), Kvit, Tally, Tessera, Nota, Signum, Vesper (taken).

Identifiers: the bundle id and the Android application id are `org.evsyukov.lists`, the Rust crate is `lists-core`.

## Languages: three, each in its place

The web server `lists-web` (directory `web/`) is written in the same Rust and uses the core directly, without bindings; its page is one HTML file with JavaScript.

| Layer | Language | What lives in it |
|---|---|---|
| Core | Rust | data model, SQLite, merging of changes, sync, repeats, parsing of the quick entry line |
| macOS | Swift, SwiftUI and AppKit (task list, cards, sidebar) | windows, menu bar, global hotkey, Share Extension, quick entry helper, system calendar events (EventKit) |
| Android | Kotlin, Jetpack Compose | screens, share target, Quick Settings tile, shortcuts, system calendar events (`CalendarContract`) |

The core is connected to both shells through UniFFI: it generates Swift and Kotlin bindings from annotations in the Rust code.

Why not one language. Everything that defines the correctness of the data must exist in one copy: two independently written merges of changes sooner or later diverge in some detail, and the devices stop converging to one state. The interface, on the contrary, is better written in the language of the platform, because the points of quick entry (the "Share" extension, the menu bar, the global hotkey, the tile, the shortcuts) are system APIs, and cross-platform UI toolkits give access to them either late or through the same Swift and Kotlin.

Alternatives considered:

- **Kotlin Multiplatform + Compose Multiplatform.** One language for everything, but on macOS Compose runs only as a JVM application: there is no native macOS target in the table of supported platforms. It is not a native app, and the "Share" extension in it would still have to be written in Swift.
- **Flutter.** The interface is drawn by its own engine; the extension is written in Swift, the global hotkey relies on a third-party package that has not been updated for about two years.
- **Swift on both platforms.** The official Swift SDK for Android came out in Swift 6.3 (March 2026), but it is a shared logic layer without an interface. Too young for a data store.
- **Tauri 2.** The interface in the system webview.

The price of the chosen option: UniFFI has not reached version 1.0 and breaks compatibility between minor versions, so the version is pinned exactly, and the boundary between the core and the shells is kept narrow: only records, enums, synchronous methods of one object and a few stateless free functions (date shift, connection check, line break in a note).

## Repository: one

```
core/      Rust crate lists-core and its tests
apple/     Xcode project (described in project.yml for xcodegen), the app, the extension and the tests of Shared/
android/   Gradle project, module app
web/       web server lists-web on the same core
scripts/   building the core for each platform and generating the bindings
docs/      decisions and specifications
```

The data format, the database schema and the interface of the core change together with the screens that use them. In one repository such a change is one commit, and it either builds on both platforms or does not. In three repositories the same change turns into three coordinated releases with core versions, and a project with one developer has no consumers for whom that would be worth doing.

## Storage on the device

The data lives in an SQLite file, attachments in separate files next to it, named by the SHA-256 of their content. Such a file has neither a name nor an extension, so for the system preview and for the default app macOS makes a copy under the original name in a temporary folder (`AttachmentFiles`); a copy and not a link, so that an app that saves the file over the opened one does not change the content under its hash. On Android the file goes out through `FileProvider` with the original name, and the app draws images and PDFs itself (`BitmapFactory`, `PdfRenderer`), without third-party libraries. SQLite is built into the core (rusqlite with `bundled`), so the version is the same on all platforms.

- macOS: the App Group directory. Only it is accessible to both the app and the "Share" extension. A build without a signing team has no group and keeps the data in Application Support.
- Android: the app's internal `filesDir`. Closed to other apps, encrypted since Android 10, needs no permissions.

The database is opened in WAL mode: the extension, the quick entry helper and the app on macOS write to one file from different processes.

On Android the database is opened in the background when the process starts (`ListsApp`): opening may make a copy before a migration and the migration itself, and the main thread does not wait for them. Screens also read the core off the main thread, through `fromStore`, which hands the value to the composition once it is read; writes go through coroutines on `Dispatchers.IO`. The debug build turns on StrictMode with logging to the system log: disk access from the main thread is visible in `adb logcat` under the tag `StrictMode` (#320).

The quick entry helper (R115) is a second program inside `Lists.app`, in `Contents/Library/LoginItems`. It is started by a user launch agent (`~/Library/LaunchAgents`, `launchctl bootstrap`), not by `SMAppService.loginItem`: that one starts the helper only from an app signed by a developer, and in an ad hoc signed build the system stops it at launch ("Launch Constraint Violation") while reporting that it is enabled; checked on 2026-10-11. Lists itself is started at login by `SMAppService.mainApp`. The helper is built from the same sources as the app, with the compilation condition `LISTS_HELPER` and its own entry point: the quick entry window is shared by both programs, and everything that belongs to Lists (sync, notifications, backups, the calendar) is turned off in the helper. The helper has no settings of its own: it reads and writes the settings of Lists (`Storage.defaults`). It tells the app about a change in the data with the same notification as the extension.

Backups (R87–R90 in [product.md](specs/product.md)) live in the same place, in the `backups` folder: each is a zip with the table of fields and the content of the attachments. Restoring does not replace the database file; in one transaction it replaces the fields in the open database and rebuilds the derived tables, so the second process on macOS keeps working with the same file. The table of fields and the service tables have a schema version number (`schema_version` in the `meta` table, `SCHEMA_VERSION` in `core/src/db.rs`). A change that rewrites their content raises the number; a database with a lower number is first copied by the core on opening with the same mechanism and only then migrated (R92). The derived tables live under their own number, `derived_version`: they are rebuilt from the fields, and no copy is needed for that.

The activity log (R102 in [product.md](specs/product.md)) is a text file `log.txt` in the same folder. The core writes it, so the lines about sync, backups and import are the same on macOS and Android; the shell adds through the core only a line about its own start. The level is kept in the `meta` table and is not synced. The file is limited to 1 MB, the previous one is kept next to it as `log.1.txt`; the log is not part of a backup. An attachment that the second pass of sync could not transfer is remembered by the core in `meta` (key `blob_trouble:<hash>`: since when, and when the last ERROR line was written), so that a repeat of the same failure is not logged as an error on every pass and after every restart of the process. Failures of calls whose error the apps only show or discard (adding and downloading an attachment, the notification plan, the push address) are logged by the core itself. The log gets outcomes and numbers, not the content of tasks: the message is built by the calling code of the core, and there is no general error interceptor that could write someone else's text.

## Sync: a change log over WebDAV; CalDAV as the second transport

What is done. Every field of every record is a "last writer wins" register with a hybrid logical clock stamp (the technique is called CRDT, conflict-free replicated data type). Edits to different fields of one task from different devices merge without loss, and the result does not depend on the order of delivery. Devices exchange immutable change files through a "dumb" storage: a WebDAV directory or an ordinary folder. Each device writes only files with its own name, so there are no write conflicts on the server and no locks are needed. The format and the rules are in [specs/sync.md](specs/sync.md).

Key limit (S51, #317). The kind, the identifier and the field name of a register are non-empty and no longer than 200 bytes of UTF-8; a change with any other key is not applied. A tag is the field `tag:<name>`, so a tag name is no longer than 196 bytes. One predicate, `db::key_ok`, is used both for accepting changes from the network and from a backup and for writing a tag: local paths do not create a field that another device would reject. A tag over the limit is rejected on input, import skips it and names it in the report, CalDAV does not read it; a tag longer than the limit written by an earlier version is not shown after the update. The derived tables, `task_tags` among them, are rebuilt when their version (`derived_version`) changes, so this needs neither a new schema version nor a copy of the database.

Log compaction (#288). A snapshot of the full state is needed only by a device that has fallen behind or connects for the first time: an up-to-date device reads the next log file and does not download snapshots. So a snapshot is written when the log since the previous snapshot weighs more than the snapshot itself (S45 in [sync.md](specs/sync.md)), not by the number of files as before (64): snapshots take no more bytes than changes, whatever the changes are like. Redis decides the same way when to rewrite the AOF log (`auto-aof-rewrite-percentage`). The snapshot is compressed with gzip (S46): on the data of the author of the project on 2026-10-15 (202 tasks, 1876 fields) 246 KB of JSON become 32.5 KB. A binary encoding (UUID and stamp as bytes) was measured on the same data and rejected: 114 KB uncompressed, 29.3 KB compressed, 10 % less than gzip over JSON, while the files can no longer be read without tools. The log file is not compressed: it holds hundreds of bytes, and the gain is smaller than the overhead of a request. Compression changed the storage format number, so all devices are updated together; the author of the project accepted this while there are few users.

The root of the storage is `lists/` (#294, S49). The format number lives in `vault.json` and in the file headers, so `v1` in the folder name meant nothing after the move to format 2 and was dropped. The previous storage in `lists/v1/` is moved by the first device with the new version: file by file with a `MOVE` request, without transferring the content, and with a copy on a server without `MOVE`. Moving the whole folder with one `MOVE` was rejected, because not every server supports it. As the last step `lists/v1/vault.json` gets format 3 and stays forever: the previous version stops on it per S14, and without it would set up a new empty storage in `lists/v1/` without an error. A previous version that was running during the move writes to the old place until it restarts. The new version picks up such files at startup with one extra request, the listing of `lists/v1/log/`; it looks for attachment content there only when the content is missing from `lists/blobs/`. Decisions of the author of the project from 2026-10-16.

Attachment content in the storage is shared: the name is the hash, and one content can be held by attachments of different devices. Removal of what is no longer needed (S47, S48) therefore takes two moves: the device that removed it writes the field `blob/<hash>/gone` to the log, and a device that has meanwhile attached the same file again uploads it anew when it receives this field. The field is written after the removal, otherwise the attaching device could check the storage before the removal and never learn about it.

Ready-made libraries were rejected: Automerge has no move operation (the issue has been open since 2022), cr-sqlite has not had a release since January 2024, Loro supports a movable tree but keeps its own binary document next to SQLite, not instead of it. For records with scalar fields, per-field registers are simpler and can be tested in full.

What about CalDAV. The first version of this section rejected CalDAV entirely; a check on 2026-10-05 showed that this was too categorical. The app's own data can be put into `X-` properties of a VTODO, and the question comes down to whether they survive the server and other clients:

| What is needed | What was checked |
|---|---|
| The server returns an object with unknown `X-` properties | sabre/dav and Nextcloud store the body as sent. Radicale rebuilds the object through vobject; preservation not checked. Cyrus (presumably Fastmail) strips some `X-` properties. iCloud, Synology, Baikal not checked. |
| Other clients do not lose these properties when editing | Tasks.org and DAVx5/jtx Board keep unknown properties; Nextcloud Tasks edits properties one at a time. For Thunderbird and Apple there is no direct confirmation. |
| List settings beyond colour and order | Arbitrary collection properties are accepted by Nextcloud and Radicale; in sabre/dav this is a separate plugin, off by default. |
| Attachments | An object is limited to 10 MB (sabre/dav, Nextcloud, Radicale), so an inline attachment is up to about 7 MB; the accepted limit is 5 MB per file and 20 MB per task (C5 in [caldav.md](specs/caldav.md)). Managed attachments (RFC 8607) exist in iCloud and Cyrus. Large files would need WebDAV alongside. |
| Conflict detection and fast reconciliation | `If-Match` and `sync-collection` exist in sabre/dav and Radicale. |

What CalDAV does not give by itself: an object is replaced as a whole, so per-field merging stays with the app. This is solved the same way as now: field stamps are kept in an `X-` property, and writes go with `If-Match` and a retry after merging. Repeats are then written with a standard `RRULE`, and "one occurrence done" is still expressed by shifting the due date.

Result: CalDAV fits as a second transport for servers of the Nextcloud class, with the benefit of compatibility with other clients and with servers without WebDAV. It is implemented as the second transport: what is transferred and what is not is described in [caldav.md](specs/caldav.md).

## The web instead of iOS

The author of the project does not plan to publish an iOS app, so the phone is served by the web interface. A pure browser app is impossible: WebDAV and CalDAV servers do not send CORS headers (checked on Fastmail and iCloud; Nextcloud opens DAV to a foreign origin only with a third-party app). So the web interface comes with a small server, `lists-web`: the same core crate, its own copy of the data, sync on equal terms with the apps. It is installed on a home server and opened from the phone as a page or an icon on the Home Screen.

Notifications on the web go through Web Push (#335). The browser has no notification scheduler, so the server sends them: each subscribed browser is a separate device for it, with its own R36 settings and its own time zone. Every 30 seconds the server asks the core what has come due in the past window (`due_notifications`), encrypts the message for the browser (RFC 8291) and signs the request with its VAPID key (RFC 8292). The cryptography comes from the RustCrypto crates, without OpenSSL. The text of the notification is put together by the service worker at the moment it is shown. The service worker also keeps the page for when the server is unreachable.

## Markdown in notes: parsing in the core

A note is stored as text, as typed; formatting is a matter of display. The core parses it (`core/src/markdown.rs`, `pulldown-cmark`) and returns ranges: what to style, what to hide, what to replace with a dot, a rule or a checkbox, and which block a range belongs to. Offsets are counted in UTF-16 units, which is how `NSString`, Kotlin and JavaScript all index a string. Three parsers, one per platform, would diverge on the first edge case, and the macOS app has unit tests only for the shared code in `apple/Shared` (`apple/Tests`), Android has few; the rules live in one place and are covered by `core/tests/markdown.rs`. On the web the ranges come in the task response next to the text, and the page builds text nodes from them, not markup.

The platforms only paint. On macOS (`MarkdownTextView.swift`) the markup is hidden at the glyph level: a `NSLayoutManager` delegate returns empty glyphs for hidden characters, so the string in the text storage does not change, and undo and selection work as in an ordinary field; for this the field runs on TextKit 1. On Android (`MarkdownField.kt`) the displayed text is built by a `VisualTransformation` with an offset mapping. What Return does in a list is also decided by the core (`markdown_newline`): the platform applies the ready edit as ordinary input.

The core departs from the letter of CommonMark in one place: a lone `-` under a line of text counts as a started list item, not as a heading underline, otherwise the line above would turn into a heading with one keystroke.

## Undo: history in the core

Decided by the author of the project on 2026-10-17 (#311, R131). The undo history is kept by the core (`core/src/undo.rs`); the platforms only show the button, the menu item and ⌘Z. An action on a task goes through `Store::act`: the write remembers, for each register it writes, the previous value and the stamp it issued. Undo writes the previous values as an ordinary local write, so it syncs like any change. A task in which any of these registers has changed since then is skipped: the stamp in an LWW register is exactly the sign of "changed later", on this device, on another, by sync or by CalDAV. The unit of skipping is a step, that is, an action on one task together with its subtasks and the repeat record. An action on several tasks is a group of steps (`begin_group`/`end_group`), and one undo undoes it.

The history lives in the memory of the process, one stack per "actor": the app has one, the web server makes each login session an actor (`Store::as_actor`), otherwise tabs in different browsers would undo each other's actions. macOS keeps its own `UndoManager` for the Edit menu and the text fields: `AppModel.perform` runs a change as one group, learns from `undo_revision` whether anything went into the history, and if so puts into `UndoManager` a step that calls `Store::undo`.

Rejected: inverse operations on each platform (as before #311: `Back` on macOS and Android, `batchBack` on the server). They were three implementations of one rule, and they did not return a task to its previous place among its neighbours.

## Storage encryption

Decided by the author of the project on 2026-10-17 (#342, S54–S59, S62): the key is a passphrase made up by the user. Encryption is a wrapper over `Remote` (`core/src/sync/seal.rs`): it encrypts on `put`/`put_file`, decrypts on `get`/`get_to` and hides the content name of an attachment under an HMAC of its hash. Merging, cursors, log compaction and attachment passes work with the same logical paths as without encryption and know nothing about the key. A file that fails to open is returned by the wrapper as empty, and no reader accepts an empty file: the cursor stays in place, as with an unfinished file (S8). No separate error is introduced for this, so as not to change the error enum that the apps see.

The data key is random and is kept in `vault.json`, wrapped with a key derived from the passphrase (Argon2id), so changing the passphrase rewrites one file. Files are encrypted in 64 KiB chunks (STREAM over XChaCha20-Poly1305), so that an attachment of hundreds of megabytes streams as it does without encryption (S52); the associated data is the logical path, so a file under someone else's name does not open. The libraries are `argon2`, `chacha20poly1305`, `hmac` from RustCrypto: pure Rust, builds for macOS, Android and musl without system libraries. In the debug build `argon2` is optimised (`Cargo.toml`), otherwise deriving a key with 64 MiB would take seconds in every test.

Turning encryption on does not re-encrypt the files of other devices: the device writes a snapshot of its state under a new number and removes the rest, and each device writes its own snapshot on first opening. This way, what was uploaded in plaintext at the moment encryption was turned on is not lost, and a storage without the key stops a device at the first snapshot it cannot read.

Rejected: a key issued by a device and carried over by a QR code or a file (the author chose a passphrase); encryption for CalDAV (other clients could no longer read the tasks); encryption of log file names (sync per S9 and S17 relies on them, and all they reveal is the number of devices and edits).

## Secrets

The WebDAV password does not go into the database, nor do the CalDAV password and the push server token. On macOS it is kept in the keychain (`Keychain.swift`): all secrets in one item "Lists", which is read once per launch, because after every update an ad hoc signed build is a different app for the keychain, and the prompt appears for every item read (#241). A secret from the previous items, one per secret, is moved into the shared item on first read, and the previous item stays in place until the secret is removed. On Android it is encrypted with a key from the Android Keystore (`Secrets.kt`); the core gets it into memory after the database is opened (`Store::set_sync_password`). The passphrase of an encrypted storage (S58) is kept in the same place and the same way and goes to the core through `Store::set_sync_passphrase`. Cyberduck (keychain) and Tasks.org (Android Keystore) do the same; DAVx5 uses AccountManager.

## Sources

- 2Do: <https://www.2doapp.com/docs/macos/task-editor>, <https://www.2doapp.com/docs/macos/repeating-tasks>, <https://www.2doapp.com/docs/macos/sync-with-caldav>, <https://www.2doapp.com/docs/ios/sync-with-caldav>, <https://www.2doapp.com/docs/macos/sync-with-webdav>
- CalDAV: <https://www.rfc-editor.org/rfc/rfc5545>, <https://www.rfc-editor.org/rfc/rfc8607>, <https://standards.calconnect.org/cc/cc-s0505-2005.html>, <https://sabre.io/dav/building-a-caldav-client/>
- Stack: <https://mozilla.github.io/uniffi-rs/latest/>, <https://kotlinlang.org/docs/multiplatform/supported-platforms.html>, <https://docs.flutter.dev/platform-integration/ios/app-extensions>, <https://www.swift.org/blog/swift-6.3-released/>, <https://v2.tauri.app/start/>
- CalDAV, check of X- properties: <https://github.com/sabre-io/dav/blob/master/lib/CalDAV/Plugin.php>, <https://github.com/nextcloud/server/blob/master/apps/dav/lib/DAV/CustomPropertiesBackend.php>, <https://github.com/Kozea/Radicale/blob/master/radicale/storage/multifilesystem/upload.py>, <https://github.com/cyrusimap/cyrus-imapd/blob/master/imap/ical_support.c>, <https://github.com/tasks/tasks/blob/main/kmp/src/commonMain/kotlin/org/tasks/icalendar/VTodo.kt>, <https://github.com/bitfireAT/synctools/blob/main/lib/src/main/kotlin/at/bitfire/ical4android/JtxICalObject.kt>
- Secrets: <https://docs.cyberduck.io/cyberduck/connection/>, <https://github.com/tasks/tasks/blob/main/kmp/src/androidMain/kotlin/org/tasks/security/AndroidKeyStoreEncryption.kt>, <https://github.com/bitfireAT/davx5-ose/blob/main-ose/core/src/main/kotlin/at/bitfire/davdroid/settings/AccountManagerSettingsStore.kt>
- Sync: <https://archive.jlongster.com/using-crdts-in-the-wild>, <https://tonsky.me/blog/crdt-filesync/>, <https://martin.kleppmann.com/2021/10/07/crdt-tree-move-operation.html>, <https://github.com/automerge/automerge/issues/352>, <https://github.com/vlcn-io/cr-sqlite>
- Platforms: <https://developer.apple.com/documentation/xcode/configuring-app-groups>, <https://www.sqlite.org/wal.html>, <https://developer.android.com/training/data-storage/app-specific>, <https://github.com/sindresorhus/KeyboardShortcuts>
