//! A small command-line window into a Lists data folder, for debugging:
//!
//! ```text
//! cargo run --example lists -- <data folder> list
//! cargo run --example lists -- <data folder> add "call the bank tomorrow !!"
//! cargo run --example lists -- <data folder> webdav <url> <user>
//! LISTS_PASSWORD=… cargo run --example lists -- <data folder> sync
//! cargo run --example lists -- <data folder> sync-off
//! ```
//!
//! Close the app before pointing this at its folder.

use lists_core::{Scope, Store, SyncConfig};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let usage = "usage: lists <data folder> list | add <text> | webdav <url> <user> | sync | sync-off";
    let (dir, command) = match args.as_slice() {
        [dir, command, ..] => (dir.clone(), command.as_str()),
        _ => return Err(usage.into()),
    };
    let store = Store::open(dir)?;
    match (command, &args[2..]) {
        ("list", []) => {
            for task in store.tasks(Scope::All)? {
                println!("{}\t{}\t{}", task.list_id, task.due.unwrap_or_default(), task.title);
            }
        }
        ("add", [text]) => println!("{}", store.quick_add(text.clone(), None)?.id),
        ("webdav", [url, user]) => store.set_sync_config(SyncConfig::WebDav {
            url: url.clone(),
            user: user.clone(),
        })?,
        ("sync", []) => {
            // The password is never stored by the core; here it comes from the environment.
            store.set_sync_password(std::env::var("LISTS_PASSWORD").ok());
            println!("{:?}", store.sync_now()?)
        }
        ("sync-off", []) => store.set_sync_config(SyncConfig::Off)?,
        _ => return Err(usage.into()),
    }
    Ok(())
}
