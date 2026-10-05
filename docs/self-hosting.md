# Running the web interface

A browser cannot talk to a WebDAV or CalDAV server on another origin, so the web interface comes with a small server of its own, `lists-web`. It is one more device: it keeps a copy of the data, syncs it like the apps do, and serves a page that works on a phone and can be added to the home screen.

The server is meant for one person: everyone who signs in sees the same data.

## Docker

The image is `ghcr.io/juev/lists`, built for amd64 and arm64. Tags: the version (`0.1.0`), the minor line (`0.1`) and `latest`.

```sh
docker run -d --name lists \
  -p 8080:8080 \
  -v lists-data:/data \
  -e LISTS_WEB_PASSWORD='choose a password' \
  ghcr.io/juev/lists:latest
```

The container listens on port 8080, keeps its data in `/data` and runs as user 10001. A directory mounted over `/data` must be writable by that user.

The image holds only the server, linked statically, and a minimal init; there is no shell inside, so `docker exec` has nothing to run.

The repository carries a ready [`compose.yaml`](../compose.yaml) that reads its settings from an `.env` file. A Compose file of your own, syncing through WebDAV:

```yaml
services:
  lists:
    image: ghcr.io/juev/lists:latest
    restart: unless-stopped
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

volumes:
  lists-data:
```

Keep the two passwords in an `.env` file next to `compose.yaml`.

## Without Docker

```sh
make web
LISTS_WEB_PASSWORD=… LISTS_WEB_LISTEN=0.0.0.0:8080 web/target/release/lists-web
```

## Settings

Everything is configured through environment variables, so that no password shows up in the process list.

| Variable | Meaning | Default |
|---|---|---|
| `LISTS_WEB_LISTEN` | address and port to listen on | `127.0.0.1:8080`; `0.0.0.0:8080` in the image |
| `LISTS_WEB_DATA` | directory with this device's copy of the data | `./lists-data`; `/data` in the image |
| `LISTS_WEB_PASSWORD` | password for the web interface | none |
| `LISTS_WEB_URL` | the server's address as the browser sees it; needed for OpenID Connect | none |
| `LISTS_SYNC` | `webdav`, `caldav`, `folder` or `off` | `off` |
| `LISTS_SYNC_URL` | storage address for `webdav` and `caldav` | none |
| `LISTS_SYNC_USER` | storage user name | none |
| `LISTS_SYNC_PASSWORD` | storage password | none |
| `LISTS_SYNC_PATH` | directory for `folder` | none |
| `LISTS_OIDC_ISSUER` | address of the OpenID Connect provider | none |
| `LISTS_OIDC_CLIENT_ID` | client id registered with the provider | none |
| `LISTS_OIDC_CLIENT_SECRET` | client secret; leave out for a public client | none |
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

A session lasts 30 days.

## Reverse proxy

The server speaks plain HTTP. Put it behind a reverse proxy that terminates TLS and publish the container port on a loopback address only, as in the Compose file above. With Caddy:

```
lists.example.org {
    reverse_proxy 127.0.0.1:8080
}
```

## Backup and updates

The whole state is the `/data` volume. With sync configured it is a copy of what the storage holds, and a lost volume is rebuilt on the next sync; without sync it is the only copy, so back it up.

To update, pull the new image and recreate the container:

```sh
docker compose pull && docker compose up -d
```

## Limits

- No notifications.
- Repeats are set from the presets; custom rules made in the apps are kept and shown.
- No reordering by dragging.
- OpenID Connect was tested against a fake provider only. The signature of the ID token is not verified: the token comes straight from the provider over TLS, which OpenID Connect Core 3.1.3.7 allows.
