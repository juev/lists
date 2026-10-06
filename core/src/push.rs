//! A content-free nudge between devices: "something changed, sync now".
//! Rules: S18–S21 in docs/specs/sync.md.

use std::time::Duration;

use crate::db;
use crate::error::{AppError, Result};
use crate::store::Store;

const ENDPOINT_KEY: &str = "push_endpoint";

fn is_http(url: &str) -> bool {
    url.starts_with("https://") || url.starts_with("http://")
}

/// Asks whoever listens at each address to sync. Best effort: an address that
/// does not answer changes nothing for the sender.
pub(crate) fn poke<'a>(urls: impl IntoIterator<Item = &'a str>) {
    let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(5)).build();
    for url in urls.into_iter().filter(|u| is_http(u)) {
        let _ = agent.post(url).send_string("sync");
    }
}

#[uniffi::export]
impl Store {
    /// The address other devices should send a nudge to, or `None` to stop
    /// receiving them. It is published in the storage by the next sync run.
    pub fn set_push_endpoint(&self, url: Option<String>) -> Result<()> {
        let inner = self.lock();
        match url.as_deref().map(str::trim).filter(|u| !u.is_empty()) {
            Some(url) if is_http(url) => db::meta_set(&inner.conn, ENDPOINT_KEY, url),
            Some(_) => Err(AppError::sync("the address must start with https:// or http://")),
            None => db::meta_del(&inner.conn, ENDPOINT_KEY),
        }
    }

    pub fn push_endpoint(&self) -> Result<Option<String>> {
        db::meta_get(&self.lock().conn, ENDPOINT_KEY)
    }
}
