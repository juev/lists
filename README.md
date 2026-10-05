# Lists

A local-first to-do list with native apps for macOS and Android, a self-hosted web interface, and sync through storage you already own: a WebDAV folder, a CalDAV server or a plain directory. No account, no service to subscribe to.

Lists covers the part of 2Do that a single person uses every day: lists, dates, priorities, tags, repeats, attachments and subtasks that are full tasks. Everything works offline; edits made on two devices to different fields of the same task are both kept.

The interface is in English with a Russian localization and follows the system language.

## Layout

| Path | What |
|---|---|
| `core/` | Rust crate: storage (SQLite), merge of concurrent edits, sync, recurrence, quick-entry parsing |
| `apple/` | macOS app and share extension, SwiftUI |
| `android/` | Android app, Kotlin and Jetpack Compose |
| `web/` | `lists-web`: a small server with the same core and a web interface, for phones without a native app |
| `scripts/` | builds the core for each platform and generates the bindings |
| `docs/` | [decisions](docs/architecture.md), [features and interface](docs/specs/product.md), [data and sync](docs/specs/sync.md), [CalDAV](docs/specs/caldav.md), [screenshots](docs/screenshots/) |

The apps reach the core through [UniFFI](https://mozilla.github.io/uniffi-rs/) bindings generated at build time; generated files are not committed.

## Building

Core, on any machine with Rust:

```sh
make test    # unit tests, behaviour tests, sync tests, sync over a local WebDAV server
make lint    # rustfmt and clippy
```

macOS app (Xcode 16 or newer, `brew install xcodegen`):

```sh
make apple        # apple/build/Build/Products/Debug/Lists.app
make apple-run
```

The share extension and the app share one database through an App Group, which needs a signing team. The build takes the team from `LISTS_TEAM_ID` or from the first "Apple Development" certificate in the keychain. Without a team the app is signed ad hoc and keeps its data in Application Support; the share extension then has no access to it.

Android app (JDK 17 or newer, Android SDK with platform 36 and an NDK, `rustup target add aarch64-linux-android x86_64-linux-android`, `cargo install cargo-ndk`):

```sh
make android           # android/app/build/outputs/apk/debug/app-debug.apk
make android-install   # onto the connected device or emulator
```

`JAVA_HOME` and `ANDROID_HOME` default to the Homebrew and Android Studio locations on macOS; override them in the environment.

## Web interface

A browser cannot talk to a WebDAV or CalDAV server on another origin, so the web interface comes with a small server of its own. It is one more device: it keeps a copy of the data, syncs it like the apps do, and serves a page that works on a phone and can be added to the home screen.

```sh
make web
LISTS_WEB_PASSWORD=… LISTS_WEB_LISTEN=0.0.0.0:8080 \
LISTS_SYNC=webdav LISTS_SYNC_URL=https://… LISTS_SYNC_USER=… LISTS_SYNC_PASSWORD=… \
web/target/release/lists-web
```

There are two ways to sign in, usable together: a password (`LISTS_WEB_PASSWORD`) and an OpenID Connect provider such as Keycloak, Authentik or Authelia:

```sh
LISTS_OIDC_ISSUER=https://id.example.org/realms/home \
LISTS_OIDC_CLIENT_ID=lists LISTS_OIDC_CLIENT_SECRET=… \
LISTS_OIDC_ALLOW=me@example.org \
LISTS_WEB_URL=https://lists.example.org
```

Register `<LISTS_WEB_URL>/auth/callback` as the redirect address. The flow is authorization code with PKCE; only the addresses (or subject ids) in `LISTS_OIDC_ALLOW` are let in, and the variable is required. Without any login the server only accepts a loopback address. Put it behind a reverse proxy that terminates TLS. All settings are listed at the top of `web/src/main.rs`.

## Sync

| Kind | What is stored | When to pick it |
|---|---|---|
| WebDAV or folder | the app's own change log, full fidelity | any WebDAV server, a mounted share, a folder synced by another tool |
| CalDAV | one VTODO per task, a calendar per list | tasks should also be visible in other CalDAV clients |

With CalDAV everything the app knows travels in a custom property next to the standard ones, edits made by other clients are picked up, and their own properties are preserved. Servers that strip unknown properties reduce it to the standard fields. Details: [docs/specs/caldav.md](docs/specs/caldav.md).

## Trying sync without a server

```sh
cd core
cargo run --example webdav -- /tmp/lists-dav 8765
```

This serves a folder over WebDAV and CalDAV with user `user` and password `secret`. Point the macOS app at `http://127.0.0.1:8765` and the Android emulator at `http://10.0.2.2:8765`. `cargo run --example lists` is a small command-line tool for looking into a data folder; it takes the password from `LISTS_PASSWORD`.

## Notifications

Each device has its own notification settings: how long before a timed due date to remind, at what time to remind about tasks due on a day, and an optional summary of the day. A reminder set on a task itself always wins. The web interface does not notify.

## Import

A file from another task manager can be imported from File → Import… on macOS, from Settings on Android and from the sidebar of the web interface: a 2Do backup (`.2dodb`), a Todoist CSV template, a Trello board JSON, or Microsoft To Do lists as JSON. Importing the same file again updates what is already there. What each importer carries over, and what it cannot, is in [docs/specs/import.md](docs/specs/import.md).

## Quick entry

One line becomes a task: `отчёт в пятницу 10:00 !! #работа @Проекты` sets the due date, a medium priority, a tag and the list. Dates are understood in Russian and English.

- macOS: a global hotkey (⌃⌥Space by default, changeable in Settings), the menu bar item, the share extension, the Services menu, and the `lists://add?text=…` URL.
- Android: the bar at the bottom of the main screen; a small window over the current app from Share, from the text-selection menu, from the launcher shortcut and from the quick settings tile.

## Status

Version 0.1.0. What is implemented and how each part was checked is listed at the end of [docs/specs/product.md](docs/specs/product.md). Known gaps: no iOS app (the web interface covers the phone), no encryption of the data in the storage, and manual reordering on Android is not there. The WebDAV password is kept in the macOS keychain and, on Android, encrypted with a key from the Android Keystore; it is never written to the database.

## License

MIT.
