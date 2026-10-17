# Running the web interface

A browser cannot talk to a WebDAV or CalDAV server on another origin, so the web interface comes with a small server of its own, `lists-web`. It is one more device: it keeps a copy of the data, syncs it like the apps do, and serves a page that works on a phone and can be added to the home screen.

The server is meant for one person: everyone who signs in sees the same data.

## Docker

The image is `ghcr.io/juev/lists`, built for amd64 and arm64. Tags: the version (`0.5.2`), the minor line (`0.5`) and `latest`. Pre-releases get the version tag only; every version is listed on the [releases page](https://github.com/juev/lists/releases). Run the same release as the apps: 0.5.0 and 0.5.1 changed how a WebDAV or folder storage is kept, and a server older than the apps stops syncing with it.

The server speaks plain HTTP, and the password and the session cookie travel in clear text. Publish the port on a loopback address only and put a [reverse proxy](#reverse-proxy) with TLS in front:

```sh
docker run -d --name lists \
  -p 127.0.0.1:8080:8080 \
  -v lists-data:/data \
  -e LISTS_WEB_PASSWORD='choose a password' \
  -e LISTS_TRUST_PROXY=1 \
  ghcr.io/juev/lists:0.5.2
```

The container listens on port 8080, keeps its data in `/data` and runs as user 10001. A directory mounted over `/data` must be writable by that user. Uploads and imports are written to `/data/tmp` first (`TMPDIR`), so the server needs nothing outside `/data` and runs with a read-only root filesystem.

The image holds only the server, linked statically, and a minimal init; there is no shell inside, so `docker exec` has nothing to run.

`GET /healthz` answers `ok` without a login, for the health check of a reverse proxy or a monitor. The image checks itself with `lists-web healthcheck` every 30 seconds, and `docker ps` shows the container as `healthy` or `unhealthy`.

The repository carries a ready [`compose.yaml`](../compose.yaml) that reads its settings from an `.env` file; copy [`.env.example`](../.env.example) to `.env` and fill it in. Git ignores `.env`, so the passwords in it are not committed. The file sets the version of the image (`LISTS_VERSION`), the port, the password and the settings of WebDAV sync, including the passphrase of an encrypted storage, and of the push server. The Compose file also sets `LISTS_TRUST_PROXY=1`, since it publishes the port for a reverse proxy only, and runs the container with a read-only root filesystem, without capabilities and with `no-new-privileges`. The other variables (`LISTS_SYNC_PATH`, `LISTS_WEB_URL`, `LISTS_PUSH_TOKEN`, `LISTS_OIDC_*`) are not passed on by it and need a line of their own under `environment`. A Compose file of your own, syncing through WebDAV:

```yaml
services:
  lists:
    image: ghcr.io/juev/lists:0.5.2
    restart: unless-stopped
    read_only: true
    cap_drop: [ALL]
    security_opt:
      - no-new-privileges:true
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - lists-data:/data
    environment:
      LISTS_WEB_PASSWORD: ${LISTS_WEB_PASSWORD}
      LISTS_SYNC: webdav
      LISTS_SYNC_URL: https://dav.example.org/lists
      LISTS_SYNC_USER: me
      LISTS_SYNC_PASSWORD: ${LISTS_SYNC_PASSWORD}
      LISTS_TRUST_PROXY: "1"

volumes:
  lists-data:
```

Keep the two passwords in an `.env` file next to `compose.yaml`.

## Without Docker

```sh
make web
LISTS_WEB_PASSWORD=… web/target/release/lists-web
```

The server listens on `127.0.0.1:8080`; the reverse proxy on the same machine reaches it there.

## Settings

Everything is configured through environment variables, so that no password shows up in the process list.

| Variable | Meaning | Default |
|---|---|---|
| `LISTS_WEB_LISTEN` | address and port to listen on | `127.0.0.1:8080`; `0.0.0.0:8080` in the image |
| `LISTS_WEB_DATA` | directory with this device's copy of the data | `./lists-data`; `/data` in the image |
| `LISTS_MAX_FILE_MB` | the largest attachment this server takes, in megabytes; `0` disables the limit | `512` |
| `LISTS_MAX_TASK_MB` | the most all attachments of one task may take here, in megabytes; `0` disables the limit | `2048` |
| `LISTS_WEB_PASSWORD` | password for the web interface | none |
| `LISTS_WEB_URL` | the server's address as the browser sees it; needed for OpenID Connect, and with `https://` the session cookie is marked `Secure` | none |
| `LISTS_TRUST_PROXY` | `1`: the client's address is the last one in `X-Forwarded-For`, which the reverse proxy in front appends; set it only when every request comes through that proxy | none: the address of the connection |
| `LISTS_SYNC` | `webdav`, `caldav`, `folder` or `off` | `off` |
| `LISTS_SYNC_URL` | storage address for `webdav` and `caldav` | none |
| `LISTS_SYNC_USER` | storage user name | none |
| `LISTS_SYNC_PASSWORD` | storage password | none |
| `LISTS_SYNC_PASSPHRASE` | passphrase of a WebDAV or folder storage encrypted on another device; the server opens such a storage but does not encrypt one itself; see [Sync](usage.md#encrypting-the-storage) | none |
| `LISTS_SYNC_PATH` | directory for `folder` | none |
| `LISTS_PUSH_SERVER` | address of an [ntfy](https://ntfy.sh) server through which other devices ask this one to sync at once; see [Sync](usage.md#sync) | none |
| `LISTS_PUSH_TOKEN` | access token for that server, when it requires sign-in; see [Sync](usage.md#an-ntfy-server-that-requires-sign-in) | none |
| `LISTS_OIDC_ISSUER` | address of the OpenID Connect provider | none |
| `LISTS_OIDC_CLIENT_ID` | client id registered with the provider | none |
| `LISTS_OIDC_CLIENT_SECRET` | client secret; leave out for a public client | none |
| `LISTS_VAPID_SUBJECT` | the contact that push services see for this server, `mailto:` or `https:`; see [Notifications](#notifications) | `LISTS_WEB_URL`, or the address of the project |
| `LISTS_OIDC_ALLOW` | comma-separated e-mail addresses or subject ids that may sign in | none; required with OpenID Connect |

Without `LISTS_WEB_PASSWORD` and without the `LISTS_OIDC_*` variables the server refuses to listen on anything but a loopback address.

## Signing in

There are two ways, usable together: the password and an OpenID Connect provider such as Keycloak, Authentik or Authelia.

```sh
LISTS_OIDC_ISSUER=https://id.example.org/realms/home
LISTS_OIDC_CLIENT_ID=lists
LISTS_OIDC_CLIENT_SECRET=…
LISTS_OIDC_ALLOW=me@example.org
LISTS_WEB_URL=https://lists.example.org
```

Register `<LISTS_WEB_URL>/auth/callback` as the redirect address. The flow is authorization code with PKCE. Only the addresses or subject ids in `LISTS_OIDC_ALLOW` are let in.

A session lasts 30 days. Sessions are kept in memory, so a restart of the container signs everybody out.

A wrong password is answered at once. An attempt counts as failed from its start until it succeeds, so attempts sent at the same time check no more passwords than the limit allows. After 5 wrong passwords within a minute from one client, the server answers 429 with `Retry-After` and does not check the password, the right one included, until the oldest of the five is a minute old; a successful login clears the count. Each failure is a line on the standard error stream with the client's address and the number of failures in the last minute; the password is not written. Behind a reverse proxy every request comes from the proxy's address, so set `LISTS_TRUST_PROXY=1` there, or a guesser locks everybody out of the password login. At most 1000 sign-ins through OpenID Connect may be under way at once; beyond that a new one pushes out the oldest, which then has to start again.

## Reverse proxy

The server speaks plain HTTP. Put it behind a reverse proxy that terminates TLS and publish the container port on a loopback address only, as in the Compose file above. With Caddy:

```
{
    servers {
        timeouts {
            read_header 10s
            read_body 30s
        }
    }
}

lists.example.org {
    reverse_proxy 127.0.0.1:8080
}
```

Caddy passes the client's address in `X-Forwarded-For`, which `LISTS_TRUST_PROXY=1` makes the server use. The timeouts are the proxy's job: the server handles every request on a thread of its own, so a client that never finishes its request does not hold up anyone else, but it has no read timeout of its own and keeps such a connection open until the client goes away. With nginx, `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;` passes the address, and `client_header_timeout` and `client_body_timeout` (60 seconds by default) close a slow client.

## Backup and updates

The whole state is the `/data` volume, including the notification key and the subscriptions of the browsers. With sync configured it is a copy of what the storage holds, and a lost volume is rebuilt on the next sync; without sync it is the only copy, so back it up. CalDAV is the exception: the shared settings and an attachment over 5 MB do not travel through it and exist on the volume only.

Before a new version changes how the data is stored, the server puts a backup of the data into `/data/backups`. It is an ordinary backup of Lists, and the app for macOS or Android restores from it; the server has no command for that.

To update, pull the new image and recreate the container:

```sh
docker compose pull && docker compose up -d
```

## Notifications

The web interface sends the notifications of the apps through Web Push: reminders, notifications derived from due dates and the summary of the day. Open "Notifications…" in the side panel and turn on "Show notifications in this browser". Each browser has its own settings, kept on the server and not synced. "Send a test notification" sends one at once.

A browser takes notifications only from a page opened over HTTPS, so the server has to sit behind the reverse proxy below; `localhost` works too. On iPhone and iPad, add Lists to the Home Screen first (iOS 16.4 or newer) and turn the notifications on there. The server reaches the push service of the browser (Google, Mozilla, Apple) over outbound HTTPS.

The message is encrypted for the browser, so the push service sees neither the title nor the due date. The server signs its requests with a key it makes on first start and keeps in `/data/web-push-key`; the subscriptions live in `/data/web-push.json`. Losing the key means every browser has to turn notifications on again. The server looks for due notifications every 30 seconds and sends each once. A notification whose time passed while the server was down is not sent.

## Time zone

The server needs no time zone of its own, and the image has none. Each request from the page carries the browser's offset from UTC, and the server takes today, the time of a quick entry without a date and the end of the day from it. People in different zones can use one server. A request without the offset, from a script for example, is answered on the server's clock, which is UTC in the image.

## Limits

- Repeats are set from the presets; custom rules made in the apps are kept and shown.
- No reordering by dragging.
- OpenID Connect was tested against a fake provider only. The signature of the ID token is not verified: the token comes straight from the provider over TLS, which OpenID Connect Core 3.1.3.7 allows.
