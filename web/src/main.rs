//! `lists-web`: serves the web interface. Everything is configured through
//! the environment, so the password never shows up in the process list.
//!
//! ```text
//! LISTS_WEB_PASSWORD=…          password for the web interface (required unless listening on loopback)
//! LISTS_OIDC_ISSUER=https://…  sign in through an OpenID Connect provider (with or instead of the password)
//! LISTS_OIDC_CLIENT_ID=…       the redirect address to register is <LISTS_WEB_URL>/auth/callback
//! LISTS_OIDC_CLIENT_SECRET=…   leave out for a public client; PKCE is used either way
//! LISTS_OIDC_ALLOW=a@b.c,…     e-mail addresses or subject ids that may sign in (required with OIDC)
//! LISTS_WEB_URL=https://…      this server's address as the browser sees it
//! LISTS_WEB_LISTEN=127.0.0.1:8080
//! LISTS_WEB_DATA=./lists-data   where this device keeps its copy
//! LISTS_SYNC=webdav|caldav|folder|off
//! LISTS_SYNC_URL=https://…      for webdav and caldav
//! LISTS_SYNC_USER=…
//! LISTS_SYNC_PASSWORD=…
//! LISTS_SYNC_PATH=/path         for folder
//! ```

use lists_core::SyncConfig;
use lists_web::{start, Config, OidcConfig};

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

fn main() {
    let listen = env("LISTS_WEB_LISTEN").unwrap_or_else(|| "127.0.0.1:8080".into());
    let password = env("LISTS_WEB_PASSWORD");
    let loopback = listen.starts_with("127.") || listen.starts_with("localhost:") || listen.starts_with("[::1]");
    let oidc = env("LISTS_OIDC_ISSUER").map(|issuer| OidcConfig {
        issuer,
        client_id: env("LISTS_OIDC_CLIENT_ID").unwrap_or_default(),
        client_secret: env("LISTS_OIDC_CLIENT_SECRET").unwrap_or_default(),
        public_url: env("LISTS_WEB_URL").unwrap_or_default(),
        allow: env("LISTS_OIDC_ALLOW")
            .unwrap_or_default()
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect(),
    });
    if password.is_none() && oidc.is_none() && !loopback {
        eprintln!("lists-web: set LISTS_WEB_PASSWORD or the LISTS_OIDC_* variables to listen on {listen}; without a login only a loopback address is served");
        std::process::exit(2);
    }
    let url = env("LISTS_SYNC_URL").unwrap_or_default();
    let user = env("LISTS_SYNC_USER").unwrap_or_default();
    let sync = match env("LISTS_SYNC").as_deref() {
        Some("webdav") => SyncConfig::WebDav { url, user },
        Some("caldav") => SyncConfig::CalDav { url, user },
        Some("folder") => SyncConfig::Folder {
            path: env("LISTS_SYNC_PATH").unwrap_or_default(),
        },
        Some("off") | None => SyncConfig::Off,
        Some(other) => {
            eprintln!("lists-web: unknown LISTS_SYNC={other}; use webdav, caldav, folder or off");
            std::process::exit(2);
        }
    };
    let config = Config {
        data_dir: env("LISTS_WEB_DATA").unwrap_or_else(|| "lists-data".into()),
        listen,
        password,
        oidc,
        sync,
        sync_password: env("LISTS_SYNC_PASSWORD"),
    };
    match start(config) {
        Ok(running) => {
            println!("lists-web: http://{}", running.addr);
            loop {
                std::thread::park();
            }
        }
        Err(e) => {
            eprintln!("lists-web: {e}");
            std::process::exit(1);
        }
    }
}
