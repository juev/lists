//! `lists-web`: serves the web interface. Everything is configured through
//! the environment, so the password never shows up in the process list.
//!
//! ```text
//! LISTS_WEB_PASSWORD=…          password for the web interface (required unless listening on loopback)
//! LISTS_WEB_LISTEN=127.0.0.1:8080
//! LISTS_WEB_DATA=./lists-data   where this device keeps its copy
//! LISTS_SYNC=webdav|caldav|folder|off
//! LISTS_SYNC_URL=https://…      for webdav and caldav
//! LISTS_SYNC_USER=…
//! LISTS_SYNC_PASSWORD=…
//! LISTS_SYNC_PATH=/path         for folder
//! ```

use lists_core::SyncConfig;
use lists_web::{start, Config};

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

fn main() {
    let listen = env("LISTS_WEB_LISTEN").unwrap_or_else(|| "127.0.0.1:8080".into());
    let password = env("LISTS_WEB_PASSWORD");
    let loopback = listen.starts_with("127.") || listen.starts_with("localhost:") || listen.starts_with("[::1]");
    if password.is_none() && !loopback {
        eprintln!("lists-web: set LISTS_WEB_PASSWORD to listen on {listen}; without a password only a loopback address is served");
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
