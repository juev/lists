//! A content-free nudge between devices: "something changed, sync now".
//! Rules: S18–S23 and S27–S30 in docs/specs/sync.md.

use std::io::{BufRead, BufReader};
use std::time::{Duration, Instant};

use sha2::{Digest, Sha256};

use crate::db;
use crate::error::{AppError, Result};
use crate::store::Store;

const ENDPOINT_KEY: &str = "push_endpoint";
const SERVER_KEY: &str = "push_server";
const TOPIC_KEY: &str = "push_topic";
const SEND_SERVER_KEY: &str = "push_send_server";
/// ntfy sends a keep-alive line every 45 seconds; silence longer than this is a dead connection.
const SILENCE: Duration = Duration::from_secs(120);

fn is_http(url: &str) -> bool {
    url.starts_with("https://") || url.starts_with("http://")
}

/// Scheme, host and port, read the way the HTTP client reads them: an address
/// that only looks like the own server must not get the token.
fn origin(url: &str) -> Option<url::Origin> {
    url::Url::parse(url).ok().map(|u| u.origin())
}

fn refused<T>(answer: &std::result::Result<T, ureq::Error>) -> bool {
    matches!(answer, Err(ureq::Error::Status(401 | 403, _)))
}

fn server_address(server: Option<&str>) -> Result<Option<&str>> {
    match server.map(|s| s.trim().trim_end_matches('/')).filter(|s| !s.is_empty()) {
        Some(server) if is_http(server) => Ok(Some(server)),
        Some(_) => Err(AppError::sync("the address must start with https:// or http://")),
        None => Ok(None),
    }
}

impl Store {
    /// Asks whoever listens at each address to sync. Best effort: an address that
    /// does not answer changes nothing for the sender.
    pub(crate) fn poke<'a>(&self, urls: impl IntoIterator<Item = &'a str>) {
        let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(5)).build();
        let own = self.own_server();
        let token = self.token();
        let (mut passed, mut denied) = (false, false);
        for url in urls.into_iter().filter(|u| is_http(u)) {
            // S28: the token goes to the own server and nowhere else.
            let at_home = own.is_some() && origin(url) == own;
            let mut request = agent.post(url);
            if let Some(token) = token.as_ref().filter(|_| at_home) {
                request = request.set("Authorization", &format!("Bearer {token}"));
            }
            let answer = request.send_string("sync");
            if at_home {
                passed |= answer.is_ok();
                denied |= refused(&answer);
            }
        }
        if passed || denied {
            self.refusals().1 = denied;
        }
    }

    fn own_server(&self) -> Option<url::Origin> {
        let server = match self.push_server() {
            Ok(Some(server)) => Some(server),
            _ => self.push_send_server().ok().flatten(),
        };
        server.as_deref().and_then(origin)
    }

    fn token(&self) -> Option<String> {
        self.push_token.lock().unwrap_or_else(|p| p.into_inner()).clone()
    }

    fn refusals(&self) -> std::sync::MutexGuard<'_, (bool, bool)> {
        self.push_refused.lock().unwrap_or_else(|p| p.into_inner())
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

    /// S22: takes nudges through an ntfy server, or stops with `None`. The
    /// device picks a random topic once and publishes `<server>/<topic>` as
    /// its address; `wait_for_nudge` listens there.
    pub fn set_push_server(&self, server: Option<String>) -> Result<()> {
        let Some(server) = server_address(server.as_deref())? else {
            db::meta_del(&self.lock().conn, SERVER_KEY)?;
            *self.refusals() = (false, false);
            return self.set_push_endpoint(None);
        };
        *self.refusals() = (false, false);
        // Read first: a guard held across the match would deadlock the arms.
        let known = db::meta_get(&self.lock().conn, TOPIC_KEY)?;
        let topic = match known {
            Some(topic) => topic,
            None => {
                // The name is the only secret: it has to be unguessable, not just unique.
                let mut seed = Sha256::new();
                seed.update(uuid::Uuid::now_v7().as_bytes());
                seed.update(self.device_id());
                seed.update(format!("{:?}{:p}", Instant::now(), self));
                let topic = crate::store::hex(&seed.finalize())[..32].to_string();
                db::meta_set(&self.lock().conn, TOPIC_KEY, &topic)?;
                topic
            }
        };
        db::meta_set(&self.lock().conn, SERVER_KEY, server)?;
        self.set_push_endpoint(Some(format!("{server}/{topic}")))
    }

    pub fn push_server(&self) -> Result<Option<String>> {
        db::meta_get(&self.lock().conn, SERVER_KEY)
    }

    /// S29: the ntfy server the token belongs to on a device that takes
    /// nudges some other way and so has no push server. Only sending uses it.
    pub fn set_push_send_server(&self, server: Option<String>) -> Result<()> {
        let server = server_address(server.as_deref())?;
        *self.refusals() = (false, false);
        let inner = self.lock();
        match server {
            Some(server) => db::meta_set(&inner.conn, SEND_SERVER_KEY, server),
            None => db::meta_del(&inner.conn, SEND_SERVER_KEY),
        }
    }

    pub fn push_send_server(&self) -> Result<Option<String>> {
        db::meta_get(&self.lock().conn, SEND_SERVER_KEY)
    }

    /// S27: keeps the access token of the own ntfy server for this process
    /// only, the way `set_sync_password` keeps the password.
    pub fn set_push_token(&self, token: Option<String>) {
        let token = token.map(|t| t.trim().to_string()).filter(|t| !t.is_empty());
        *self.push_token.lock().unwrap_or_else(|p| p.into_inner()) = token;
        *self.refusals() = (false, false);
    }

    /// S30: whether the own server answered the last subscription or the last
    /// nudge with 401 or 403: the token is wrong, missing or not allowed there.
    pub fn push_refused(&self) -> bool {
        let refusals = self.refusals();
        refusals.0 || refusals.1
    }

    /// Blocks until another device asks this one to sync and returns `true`;
    /// the caller then runs a sync and calls again. Returns `false` when
    /// there was nothing to wait for or the wait has to start over: no server
    /// is set, it could not be reached, or the setting changed meanwhile. It
    /// never returns sooner than ten seconds after a failure, so calling it
    /// in a loop is safe. Meant for a thread of its own.
    pub fn wait_for_nudge(&self) -> bool {
        let started = Instant::now();
        let retry = *self.push_retry.lock().unwrap_or_else(|p| p.into_inner());
        // Holds back a caller that would otherwise come straight back.
        let pause = || std::thread::sleep(retry.saturating_sub(started.elapsed()));
        let listening_at = match (self.push_server(), self.push_endpoint()) {
            (Ok(Some(_)), Ok(Some(endpoint))) => endpoint,
            _ => {
                pause();
                return false;
            }
        };
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(15))
            .timeout_read(SILENCE)
            .build();
        let token = self.token();
        let mut request = agent.get(&format!("{listening_at}/json"));
        if let Some(token) = token.as_ref().filter(|_| origin(&listening_at) == self.own_server()) {
            request = request.set("Authorization", &format!("Bearer {token}"));
        }
        let answer = request.call();
        // S30: only an answer says anything about the token; a server that is away does not.
        if answer.is_ok() || refused(&answer) {
            self.refusals().0 = answer.is_err();
        }
        let Ok(response) = answer else {
            pause();
            return false;
        };
        for line in BufReader::new(response.into_reader()).lines() {
            match line {
                Ok(line) if line.contains(r#""event":"message""#) => return true,
                Ok(_) => {
                    // Any other line, a keep-alive among them, is the moment to
                    // notice that the setting changed.
                    if self.push_endpoint().ok().flatten().as_ref() != Some(&listening_at) || self.token() != token {
                        return false;
                    }
                }
                Err(_) => break,
            }
        }
        // S23: the connection broke; a nudge may have been missed. A server
        // that drops everyone at once must not be asked in a tight loop.
        pause();
        true
    }
}
