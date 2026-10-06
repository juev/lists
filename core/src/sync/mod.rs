//! Sync through dumb file storage. Layout and rules: docs/specs/sync.md.
//!
//! ```text
//! lists/v1/vault.json
//! lists/v1/log/<device>-<seq>.jsonl     immutable batch of field changes
//! lists/v1/log/<device>-<seq>.snap      empty: the device has a snapshot as of <seq>
//! lists/v1/snap/<device>-<seq>.jsonl    full state of a device as of its log <seq>
//! lists/v1/blobs/<aa>/<sha256>          attachment content
//! ```
//!
//! A device only ever writes files carrying its own id, so two devices never
//! write the same file and no locking is needed.

pub mod remote;
pub mod webdav;

use std::collections::{BTreeMap, BTreeSet};

use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::db::{self, is_sha256, Change, Touched};
use crate::error::{AppError, Result};
use crate::model::{SyncConfig, SyncReport, SyncStatus};
use crate::store::{hex, Store};
use remote::{DirRemote, Remote};
use webdav::WebDavRemote;

const ROOT: &str = "lists/v1";
const FORMAT: u32 = 1;

#[derive(Serialize, Deserialize)]
struct Vault {
    format: u32,
    vault: String,
}

/// `push/<device>.json`: where the device takes nudges (S18).
#[derive(Serialize, Deserialize)]
struct PushRecord {
    v: u32,
    url: String,
}

#[derive(Serialize, Deserialize)]
struct Header {
    v: u32,
    device: String,
    seq: u64,
    count: usize,
    /// Snapshots only: last log file of every device already merged into this state.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    covers: BTreeMap<String, u64>,
}

struct Batch {
    header: Header,
    changes: Vec<Change>,
}

fn encode(header: &Header, changes: &[Change]) -> Result<Vec<u8>> {
    let mut out = serde_json::to_vec(header)?;
    for change in changes {
        out.push(b'\n');
        serde_json::to_writer(&mut out, change)?;
    }
    out.push(b'\n');
    Ok(out)
}

/// `None` for a file that is truncated or otherwise unreadable: the caller
/// leaves its cursor where it is and tries again on the next run.
fn decode(data: &[u8]) -> Option<Batch> {
    let text = std::str::from_utf8(data).ok()?;
    let mut lines = text.lines();
    let header: Header = serde_json::from_str(lines.next()?).ok()?;
    if header.v != FORMAT {
        return None;
    }
    let mut changes = Vec::with_capacity(header.count);
    for line in lines {
        changes.push(serde_json::from_str(line).ok()?);
    }
    (changes.len() == header.count && text.ends_with('\n')).then_some(Batch { header, changes })
}

/// Batches of changes: log files and snapshots.
const DATA: &str = ".jsonl";
/// A mark in `log/` that tells readers about a snapshot without a look into `snap/`.
const MARK: &str = ".snap";

type Index = BTreeMap<String, BTreeSet<u64>>;

fn file_name(device: &str, seq: u64) -> String {
    format!("{device}-{seq:010}{DATA}")
}

fn mark_name(device: &str, seq: u64) -> String {
    format!("{device}-{seq:010}{MARK}")
}

fn parse_name(name: &str, suffix: &str) -> Option<(String, u64)> {
    let (device, seq) = name.strip_suffix(suffix)?.split_once('-')?;
    (seq.len() == 10 && !device.is_empty()).then_some(())?;
    Some((device.to_string(), seq.parse().ok()?))
}

fn index(names: &[String], suffix: &str) -> Index {
    let mut map = Index::new();
    for (device, seq) in names.iter().filter_map(|n| parse_name(n, suffix)) {
        map.entry(device).or_default().insert(seq);
    }
    map
}

fn blob_remote_path(sha256: &str) -> String {
    format!("{ROOT}/blobs/{}/{}", &sha256[..2], sha256)
}

impl Store {
    fn cursor(&self, device: &str) -> Result<u64> {
        Ok(self
            .lock()
            .conn
            .query_row("SELECT seq FROM peers WHERE device = ?1", [device], |r| r.get(0))
            .optional()?
            .unwrap_or(0))
    }

    /// Merges a batch and moves cursors in one transaction. Returns how many registers changed.
    fn merge(&self, batch: &Batch, cursors: &BTreeMap<String, u64>) -> Result<u32> {
        let mut inner = self.lock();
        let inner = &mut *inner;
        let tx = inner
            .conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let mut touched = Touched::new();
        let mut changed = 0;
        for change in batch.changes.iter().filter(|c| c.is_well_formed()) {
            inner.clock.observe(&change.stamp);
            if db::apply(&tx, change, false, &mut touched)? {
                changed += 1;
            }
        }
        db::settle(&tx, &touched)?;
        for (device, seq) in cursors {
            tx.execute(
                "INSERT INTO peers (device, seq) VALUES (?1, ?2)
                 ON CONFLICT (device) DO UPDATE SET seq = max(seq, excluded.seq)",
                params![device, *seq as i64],
            )?;
        }
        tx.commit()?;
        Ok(changed)
    }

    fn check_vault(&self, remote: &dyn Remote) -> Result<()> {
        let path = format!("{ROOT}/vault.json");
        match remote.get(&path)? {
            Some(data) => {
                let vault: Vault = serde_json::from_slice(&data)
                    .map_err(|_| AppError::sync("vault.json in the storage is not readable"))?;
                if vault.format != FORMAT {
                    return Err(AppError::sync(format!(
                        "the storage uses format {}, this version understands format {FORMAT}; update the app",
                        vault.format
                    )));
                }
                Ok(())
            }
            None => {
                let vault = Vault {
                    format: FORMAT,
                    vault: uuid::Uuid::now_v7().to_string(),
                };
                remote.put(&path, &serde_json::to_vec(&vault)?)
            }
        }
    }

    /// Whether the marks in `log/` leave something unexplained: a device whose
    /// next file is gone although later ones exist, or a known device with
    /// nothing left there. Versions that wrote no marks leave such traces.
    fn marks_fall_short(&self, me: &str, logs: &Index, marks: &Index) -> Result<bool> {
        let cursors: BTreeMap<String, u64> = {
            let inner = self.lock();
            let mut stmt = inner.conn.prepare("SELECT device, seq FROM peers")?;
            let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u64)))?;
            rows.collect::<rusqlite::Result<_>>()?
        };
        let empty = BTreeSet::new();
        Ok(logs
            .keys()
            .chain(cursors.keys())
            .filter(|d| d.as_str() != me)
            .any(|device| {
                let cursor = cursors.get(device).copied().unwrap_or(0);
                let files = logs.get(device).unwrap_or(&empty);
                if files.contains(&(cursor + 1)) || marks.get(device).and_then(|m| m.last()) > Some(&cursor) {
                    return false;
                }
                files.range(cursor + 1..).next().is_some() || (files.is_empty() && !marks.contains_key(device))
            }))
    }

    /// Reads what other devices wrote. Returns how many registers changed and
    /// whether a file could not be read.
    fn pull(&self, remote: &dyn Remote, me: &str, logs: &Index, marks: &Index, first: bool) -> Result<(u32, bool)> {
        // S17: the marks name the snapshots; `snap/` is listed only when they cannot be relied on.
        let mut snaps = marks.clone();
        if first || self.marks_fall_short(me, logs, marks)? {
            for (device, seqs) in index(&remote.list(&format!("{ROOT}/snap"))?, DATA) {
                snaps.entry(device).or_default().extend(seqs);
            }
        }
        let devices: BTreeSet<&String> = logs.keys().chain(snaps.keys()).filter(|d| d.as_str() != me).collect();
        let mut changed = 0;
        let mut unreadable = false;
        for device in devices {
            loop {
                let cursor = self.cursor(device)?;
                let next = cursor + 1;
                if logs.get(device).is_some_and(|seqs| seqs.contains(&next)) {
                    let Some(data) = remote.get(&format!("{ROOT}/log/{}", file_name(device, next)))? else {
                        break; // compacted away since the listing; the snapshot is picked up next run
                    };
                    let Some(batch) = decode(&data).filter(|b| b.header.device == *device && b.header.seq == next)
                    else {
                        unreadable = true;
                        break;
                    };
                    changed += self.merge(&batch, &BTreeMap::from([(device.clone(), next)]))?;
                    continue;
                }
                // The next log file is gone: catch up from the device's snapshot.
                let Some(snap_seq) = snaps.get(device).and_then(|s| s.last()).filter(|s| **s > cursor) else {
                    break;
                };
                let Some(data) = remote.get(&format!("{ROOT}/snap/{}", file_name(device, *snap_seq)))? else {
                    break;
                };
                let Some(batch) = decode(&data).filter(|b| b.header.device == *device) else {
                    unreadable = true;
                    break;
                };
                let mut cursors = batch.header.covers.clone();
                cursors.remove(me);
                cursors.insert(device.clone(), *snap_seq);
                changed += self.merge(&batch, &cursors)?;
            }
        }
        Ok((changed, unreadable))
    }

    /// Moves unsent changes into the outbox as one numbered file, then uploads the outbox.
    /// The file is fixed before the first upload attempt, so a retry sends the same bytes.
    fn push(&self, remote: &dyn Remote, me: &str) -> Result<u32> {
        {
            let mut inner = self.lock();
            let tx = inner
                .conn
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let changes: Vec<Change> = {
                let mut stmt =
                    tx.prepare("SELECT kind, id, field, value, stamp FROM fields WHERE dirty = 1 ORDER BY stamp")?;
                let rows = stmt.query_map([], change_from_row)?;
                rows.collect::<rusqlite::Result<_>>()?
            };
            if !changes.is_empty() {
                let seq = own_seq(&tx)? + 1;
                let header = Header {
                    v: FORMAT,
                    device: me.to_string(),
                    seq,
                    count: changes.len(),
                    covers: BTreeMap::new(),
                };
                tx.execute(
                    "INSERT INTO outbox (seq, body, changes) VALUES (?1, ?2, ?3)",
                    params![seq as i64, encode(&header, &changes)?, changes.len() as i64],
                )?;
                tx.execute("UPDATE fields SET dirty = 0 WHERE dirty = 1", [])?;
                db::meta_set(&tx, "own_seq", &seq.to_string())?;
            }
            tx.commit()?;
        }
        let mut pushed = 0;
        loop {
            let next: Option<(i64, Vec<u8>, u32)> = self
                .lock()
                .conn
                .query_row("SELECT seq, body, changes FROM outbox ORDER BY seq LIMIT 1", [], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                })
                .optional()?;
            let Some((seq, body, changes)) = next else {
                break;
            };
            remote.put(&format!("{ROOT}/log/{}", file_name(me, seq as u64)), &body)?;
            self.lock().conn.execute("DELETE FROM outbox WHERE seq = ?1", [seq])?;
            pushed += changes;
        }
        Ok(pushed)
    }

    /// S18: keeps this device's record in `push/` in step with the address it was given.
    fn publish_push(&self, remote: &dyn Remote, me: &str) -> Result<()> {
        let wanted = self.push_endpoint()?;
        if wanted == db::meta_get(&self.lock().conn, "push_published")? {
            return Ok(());
        }
        let path = format!("{ROOT}/push/{me}.json");
        match &wanted {
            Some(url) => {
                remote.put(
                    &path,
                    &serde_json::to_vec(&PushRecord {
                        v: FORMAT,
                        url: url.clone(),
                    })?,
                )?;
                db::meta_set(&self.lock().conn, "push_published", url)
            }
            None => {
                remote.delete(&path)?;
                db::meta_del(&self.lock().conn, "push_published")
            }
        }
    }

    /// S19: tells the other devices that there is something to read. Nothing
    /// here can fail the run.
    fn poke_peers(&self, remote: &dyn Remote, me: &str) {
        let own = format!("{me}.json");
        let names = remote.list(&format!("{ROOT}/push")).unwrap_or_default();
        let urls: Vec<String> = names
            .iter()
            .filter(|name| **name != own && name.ends_with(".json"))
            .filter_map(|name| remote.get(&format!("{ROOT}/push/{name}")).ok().flatten())
            .filter_map(|data| serde_json::from_slice::<PushRecord>(&data).ok())
            .map(|record| record.url)
            .collect();
        crate::push::poke(urls.iter().map(String::as_str));
    }

    /// Replaces this device's log files with one snapshot of its full state.
    fn compact(
        &self,
        remote: &dyn Remote,
        me: &str,
        own_logs: &BTreeSet<u64>,
        own_marks: &BTreeSet<u64>,
    ) -> Result<()> {
        let (body, seq) = {
            let inner = self.lock();
            let seq = own_seq(&inner.conn)?;
            let changes: Vec<Change> = {
                let mut stmt = inner
                    .conn
                    .prepare("SELECT kind, id, field, value, stamp FROM fields ORDER BY kind, id, field")?;
                let rows = stmt.query_map([], change_from_row)?;
                rows.collect::<rusqlite::Result<_>>()?
            };
            let mut covers: BTreeMap<String, u64> = {
                let mut stmt = inner.conn.prepare("SELECT device, seq FROM peers")?;
                let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u64)))?;
                rows.collect::<rusqlite::Result<_>>()?
            };
            covers.insert(me.to_string(), seq);
            let header = Header {
                v: FORMAT,
                device: me.to_string(),
                seq,
                count: changes.len(),
                covers,
            };
            (encode(&header, &changes)?, seq)
        };
        let old_snaps = index(&remote.list(&format!("{ROOT}/snap"))?, DATA)
            .remove(me)
            .unwrap_or_default();
        remote.put(&format!("{ROOT}/snap/{}", file_name(me, seq)), &body)?;
        // Only after the snapshot and its mark are in place do the files they replace go away.
        remote.put(&format!("{ROOT}/log/{}", mark_name(me, seq)), b"")?;
        for old in own_logs.iter().filter(|s| **s <= seq) {
            remote.delete(&format!("{ROOT}/log/{}", file_name(me, *old)))?;
        }
        for old in own_marks.iter().filter(|s| **s < seq) {
            remote.delete(&format!("{ROOT}/log/{}", mark_name(me, *old)))?;
        }
        for old in old_snaps.iter().filter(|s| **s < seq) {
            remote.delete(&format!("{ROOT}/snap/{}", file_name(me, *old)))?;
        }
        Ok(())
    }

    fn sync_blobs(&self, remote: &dyn Remote, report: &mut SyncReport) -> Result<()> {
        let wanted: Vec<(String, bool)> = {
            let inner = self.lock();
            let mut stmt = inner.conn.prepare(
                "SELECT DISTINCT a.sha256, EXISTS (SELECT 1 FROM blobs_uploaded b WHERE b.sha256 = a.sha256)
                 FROM attachments a JOIN tasks t ON t.id = a.task_id
                 WHERE a.deleted = 0 AND t.purged = 0",
            )?;
            let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
            rows.collect::<rusqlite::Result<_>>()?
        };
        for (sha256, uploaded) in wanted.into_iter().filter(|(s, _)| is_sha256(s)) {
            let local = self.blob_path(&sha256);
            let remote_path = blob_remote_path(&sha256);
            if local.exists() {
                if uploaded {
                    continue;
                }
                if !remote.exists(&remote_path)? {
                    remote.put(&remote_path, &std::fs::read(&local)?)?;
                    report.blobs_uploaded += 1;
                }
                self.lock()
                    .conn
                    .execute("INSERT OR IGNORE INTO blobs_uploaded (sha256) VALUES (?1)", [&sha256])?;
            } else if let Some(data) = remote.get(&remote_path)? {
                // The name is the hash: content that does not match is dropped, not stored.
                if hex(&Sha256::digest(&data)) != sha256 {
                    continue;
                }
                let tmp = local.with_extension("part");
                std::fs::write(&tmp, &data)?;
                std::fs::rename(&tmp, &local)?;
                self.lock()
                    .conn
                    .execute("INSERT OR IGNORE INTO blobs_uploaded (sha256) VALUES (?1)", [&sha256])?;
                report.blobs_downloaded += 1;
            }
        }
        Ok(())
    }

    /// One full sync run against the given storage.
    pub fn sync_with(&self, remote: &dyn Remote) -> Result<SyncReport> {
        let _running = self.sync_lock.lock().unwrap_or_else(|p| p.into_inner());
        let me = self.device_id();
        let mut report = SyncReport::default();

        // S14, S17: the format and the snapshots are looked at once per storage
        // and process, and again when something does not add up.
        let storage = remote.id();
        let first = self.storage_seen.lock().unwrap_or_else(|p| p.into_inner()).as_deref() != Some(storage.as_str());
        if first {
            self.check_vault(remote)?;
        }
        let names = remote.list(&format!("{ROOT}/log"))?;
        let mut logs = index(&names, DATA);
        let own_marks = index(&names, MARK).remove(&me).unwrap_or_default();
        let (pulled, unreadable) = self.pull(remote, &me, &logs, &index(&names, MARK), first)?;
        if unreadable && !first {
            self.check_vault(remote)?;
        }
        *self.storage_seen.lock().unwrap_or_else(|p| p.into_inner()) = Some(storage);
        report.pulled = pulled;
        report.pushed = self.push(remote, &me)?;

        let mut own_logs = logs.remove(&me).unwrap_or_default();
        let seq = own_seq(&self.lock().conn)?;
        if report.pushed > 0 {
            own_logs.insert(seq);
        }
        let limit = *self.compact_after.lock().unwrap_or_else(|p| p.into_inner());
        let forced = db::meta_get(&self.lock().conn, "force_snapshot")?.is_some();
        if forced || own_logs.len() as u32 > limit {
            self.compact(remote, &me, &own_logs, &own_marks)?;
            db::meta_del(&self.lock().conn, "force_snapshot")?;
        }

        self.sync_blobs(remote, &mut report)?;
        self.publish_push(remote, &me)?;
        if report.pushed > 0 || report.blobs_uploaded > 0 {
            self.poke_peers(remote, &me);
        }
        Ok(report)
    }

    fn password(&self, user: &str) -> Result<String> {
        match self.sync_password.lock().unwrap_or_else(|p| p.into_inner()).clone() {
            Some(password) => Ok(password),
            None if user.is_empty() => Ok(String::new()),
            None => Err(AppError::sync(
                "the password is not available on this device; enter it in the sync settings",
            )),
        }
    }

    /// Runs the configured kind of sync; `None` when sync is off.
    fn run_configured(&self) -> Result<Option<SyncReport>> {
        Ok(Some(match self.sync_config()? {
            SyncConfig::Off => return Ok(None),
            SyncConfig::Folder { path } => {
                let report = self.sync_with(&DirRemote::new(path))?;
                // What this run wrote is not news to it.
                self.folder_changed();
                report
            }
            SyncConfig::WebDav { url, user } => {
                self.sync_with(&WebDavRemote::new(&url, &user, &self.password(&user)?)?)?
            }
            SyncConfig::CalDav { url, user } => {
                let _running = self.sync_lock.lock().unwrap_or_else(|p| p.into_inner());
                crate::caldav::engine::run(self, &url, &user, &self.password(&user)?)?
            }
        }))
    }
}

fn own_seq(conn: &rusqlite::Connection) -> Result<u64> {
    Ok(db::meta_get(conn, "own_seq")?.and_then(|s| s.parse().ok()).unwrap_or(0))
}

fn change_from_row(r: &rusqlite::Row) -> rusqlite::Result<Change> {
    let value: String = r.get(3)?;
    Ok(Change {
        kind: r.get(0)?,
        id: r.get(1)?,
        field: r.get(2)?,
        value: serde_json::from_str(&value).unwrap_or(serde_json::Value::Null),
        stamp: r.get(4)?,
    })
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
enum StoredConfig {
    Folder { path: String },
    Webdav { url: String, user: String },
    Caldav { url: String, user: String },
}

#[uniffi::export]
impl Store {
    pub fn sync_config(&self) -> Result<SyncConfig> {
        let stored = db::meta_get(&self.lock().conn, "sync")?;
        Ok(
            match stored.and_then(|s| serde_json::from_str::<StoredConfig>(&s).ok()) {
                Some(StoredConfig::Folder { path }) => SyncConfig::Folder { path },
                Some(StoredConfig::Webdav { url, user }) => SyncConfig::WebDav { url, user },
                Some(StoredConfig::Caldav { url, user }) => SyncConfig::CalDav { url, user },
                None => SyncConfig::Off,
            },
        )
    }

    /// Keeps the WebDAV password for this process only. It is held in memory and
    /// never reaches the database; persisting it is the job of the platform's
    /// secret storage.
    pub fn set_sync_password(&self, password: Option<String>) {
        *self.sync_password.lock().unwrap_or_else(|p| p.into_inner()) = password;
    }

    /// Stores where to sync. Switching storage keeps local data; the next run
    /// merges it with whatever the new storage holds.
    pub fn set_sync_config(&self, config: SyncConfig) -> Result<()> {
        if config == self.sync_config()? {
            return Ok(());
        }
        let stored = match config {
            SyncConfig::Off => None,
            SyncConfig::Folder { path } => Some(StoredConfig::Folder { path }),
            SyncConfig::WebDav { url, user } => {
                WebDavRemote::new(&url, &user, "")?;
                Some(StoredConfig::Webdav { url, user })
            }
            SyncConfig::CalDav { url, user } => {
                crate::caldav::client::Client::validate(&url)?;
                Some(StoredConfig::Caldav { url, user })
            }
        };
        let mut inner = self.lock();
        let tx = inner
            .conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        match stored {
            Some(config) => db::meta_set(&tx, "sync", &serde_json::to_string(&config)?)?,
            None => db::meta_del(&tx, "sync")?,
        }
        // A different storage knows nothing of this device. Log numbering goes on
        // (a storage seen before must not get a second file with an old number),
        // and the first run publishes a snapshot so that readers there can start from it.
        tx.execute_batch(
            "DELETE FROM peers; DELETE FROM outbox; DELETE FROM blobs_uploaded;
             DELETE FROM caldav_calendars; DELETE FROM caldav_items;
             DELETE FROM meta WHERE key IN ('sync_ok', 'sync_error', 'caldav_filters_sent', 'caldav_home', 'push_published');
             UPDATE fields SET dirty = 1;",
        )?;
        db::meta_set(&tx, "force_snapshot", "1")?;
        tx.commit()?;
        Ok(())
    }

    /// For sync through a folder: whether a file appeared in its log or left
    /// it since the last call or the last run. Cheap enough to ask every couple
    /// of seconds; with any other kind of sync the answer is no.
    pub fn folder_changed(&self) -> bool {
        let Ok(SyncConfig::Folder { path }) = self.sync_config() else {
            return false;
        };
        let Ok(mut names) = DirRemote::new(path).list(&format!("{ROOT}/log")) else {
            return false;
        };
        names.sort();
        let mut seen = self.folder_seen.lock().unwrap_or_else(|p| p.into_inner());
        let changed = seen.as_ref() != Some(&names);
        *seen = Some(names);
        changed
    }

    /// Runs one sync. Does nothing when sync is not configured.
    pub fn sync_now(&self) -> Result<SyncReport> {
        let result = match self.run_configured() {
            Ok(None) => return Ok(SyncReport::default()),
            Ok(Some(report)) => Ok(report),
            Err(e) => Err(e),
        };
        let inner = self.lock();
        match &result {
            Ok(_) => {
                db::meta_set(
                    &inner.conn,
                    "sync_ok",
                    &inner.now().format("%Y-%m-%dT%H:%M").to_string(),
                )?;
                db::meta_del(&inner.conn, "sync_error")?;
            }
            Err(e) => db::meta_set(&inner.conn, "sync_error", &e.to_string())?,
        }
        result
    }

    pub fn sync_status(&self) -> Result<SyncStatus> {
        let configured = self.sync_config()? != SyncConfig::Off;
        let inner = self.lock();
        let pending: u32 = inner.conn.query_row(
            "SELECT (SELECT count(*) FROM fields WHERE dirty = 1) + (SELECT coalesce(sum(changes), 0) FROM outbox)",
            [],
            |r| r.get(0),
        )?;
        Ok(SyncStatus {
            configured,
            pending: if configured { pending } else { 0 },
            last_ok: db::meta_get(&inner.conn, "sync_ok")?,
            last_error: db::meta_get(&inner.conn, "sync_error")?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_round_trip() {
        assert_eq!(parse_name(&file_name("abc", 42), DATA), Some(("abc".into(), 42)));
        assert_eq!(parse_name("abc-42.jsonl", DATA), None);
        assert_eq!(parse_name("readme.txt", DATA), None);
        // A mark is not a batch and a batch is not a mark.
        assert_eq!(parse_name(&mark_name("abc", 42), MARK), Some(("abc".into(), 42)));
        assert_eq!(parse_name(&mark_name("abc", 42), DATA), None);
        assert_eq!(parse_name(&file_name("abc", 42), MARK), None);
    }

    #[test]
    fn truncated_file_is_rejected() {
        let change = Change {
            kind: "task".into(),
            id: "1".into(),
            field: "title".into(),
            value: serde_json::json!("x"),
            stamp: "000000000001-0000-aaaaaaaaaaaa".into(),
        };
        let header = Header {
            v: 1,
            device: "aaaaaaaaaaaa".into(),
            seq: 1,
            count: 2,
            covers: BTreeMap::new(),
        };
        let full = encode(&header, &[change.clone(), change]).unwrap();
        assert!(decode(&full).is_some());
        assert!(decode(&full[..full.len() - 1]).is_none());
        assert!(decode(&full[..full.len() / 2]).is_none());
        assert!(decode(b"").is_none());
    }
}
