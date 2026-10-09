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

use crate::db::{self, is_sha256, Change, Touched, KIND_ATTACHMENT, KIND_FILTER, KIND_LIST, KIND_TASK};
use crate::error::{AppError, Result};
use crate::hlc::Clock;
use crate::model::{Attachment, AttachmentReport, ConnectionCheck, SyncConfig, SyncReport, SyncStatus, INBOX_ID};
use crate::store::{hex, new_device_id, Store};
use remote::{DirRemote, Remote};
use webdav::WebDavRemote;

const ROOT: &str = "lists/v1";
const FORMAT: u32 = 1;

/// Set while this device is to put its data over the storage's (S38).
const REPLACE: &str = "replace_remote";
/// What the registers looked like when `kept` was filled (S39).
const KEPT_AT: &str = "replace_kept_at";

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
        self.poke(urls.iter().map(String::as_str));
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

    /// Content the storage and this device may still owe each other: hash and
    /// whether the storage is known to hold it.
    fn blobs_wanted(&self) -> Result<Vec<(String, bool)>> {
        let inner = self.lock();
        let mut stmt = inner.conn.prepare(
            "SELECT DISTINCT a.sha256, EXISTS (SELECT 1 FROM blobs_uploaded b WHERE b.sha256 = a.sha256)
             FROM attachments a JOIN tasks t ON t.id = a.task_id
             WHERE a.deleted = 0 AND t.purged = 0",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        let wanted: Vec<(String, bool)> = rows.collect::<rusqlite::Result<_>>()?;
        Ok(wanted.into_iter().filter(|(s, _)| is_sha256(s)).collect())
    }

    /// S34: how many of them are not in both places yet.
    fn blobs_waiting(&self) -> Result<u32> {
        let wanted = self.blobs_wanted()?;
        Ok(wanted
            .iter()
            .filter(|(sha256, uploaded)| !uploaded || !self.blob_path(sha256).exists())
            .count() as u32)
    }

    fn blob_uploaded(&self, sha256: &str) -> Result<()> {
        self.lock()
            .conn
            .execute("INSERT OR IGNORE INTO blobs_uploaded (sha256) VALUES (?1)", [sha256])?;
        Ok(())
    }

    /// Whether the content was sent; it is not when the storage already has it.
    fn upload_blob(&self, remote: &dyn Remote, sha256: &str) -> Result<bool> {
        let remote_path = blob_remote_path(sha256);
        let sent = !remote.exists(&remote_path)?;
        if sent {
            remote.put(&remote_path, &std::fs::read(self.blob_path(sha256))?)?;
        }
        self.blob_uploaded(sha256)?;
        Ok(sent)
    }

    /// Whether the content arrived; it does not when the storage has none or has something else.
    fn download_blob(&self, remote: &dyn Remote, sha256: &str) -> Result<bool> {
        let Some(data) = remote.get(&blob_remote_path(sha256))? else {
            return Ok(false);
        };
        // The name is the hash: content that does not match is dropped, not stored.
        if hex(&Sha256::digest(&data)) != sha256 {
            return Ok(false);
        }
        let local = self.blob_path(sha256);
        // A pass and a request (S35) may fetch the same content at once: each writes its own file.
        let tmp = local.with_extension(format!("{}.part", uuid::Uuid::now_v7().simple()));
        std::fs::write(&tmp, &data)?;
        std::fs::rename(&tmp, &local)?;
        self.blob_uploaded(sha256)?;
        Ok(true)
    }

    /// S34: one pass over attachment content against the given storage. A file
    /// that fails is left waiting and the rest go on.
    pub fn sync_attachments_with(&self, remote: &dyn Remote) -> Result<AttachmentReport> {
        let mut report = AttachmentReport::default();
        let _running = match self.blob_lock.try_lock() {
            Ok(guard) => guard,
            Err(std::sync::TryLockError::Poisoned(p)) => p.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => {
                report.waiting = self.blobs_waiting()?;
                return Ok(report);
            }
        };
        for (sha256, uploaded) in self.blobs_wanted()? {
            if self.blob_path(&sha256).exists() {
                if !uploaded && self.upload_blob(remote, &sha256).unwrap_or(false) {
                    report.uploaded += 1;
                }
            } else if self.download_blob(remote, &sha256).unwrap_or(false) {
                report.downloaded += 1;
            }
        }
        report.waiting = self.blobs_waiting()?;
        if report.uploaded > 0 {
            self.poke_peers(remote, &self.device_id());
        }
        Ok(report)
    }

    /// One run for the fields against the given storage. Attachment content is
    /// left to `sync_attachments_with` (S34).
    pub fn sync_with(&self, remote: &dyn Remote) -> Result<SyncReport> {
        let _running = self.sync_lock.lock().unwrap_or_else(|p| p.into_inner());
        self.replacing(|| self.run_with(remote))
    }

    fn run_with(&self, remote: &dyn Remote) -> Result<SyncReport> {
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

        self.publish_push(remote, &me)?;
        if report.pushed > 0 {
            self.poke_peers(remote, &me);
        }
        Ok(report)
    }

    /// Count and greatest stamp of the registers: the same while nothing was written.
    fn registers_mark(conn: &rusqlite::Connection) -> Result<String> {
        Ok(conn.query_row(
            "SELECT count(*) || ':' || coalesce(max(stamp), '') FROM fields",
            [],
            |r| r.get(0),
        )?)
    }

    /// S38, S39: a run that also puts this device's data over the storage's
    /// when that was asked for. The caller holds the sync lock.
    fn replacing(&self, run: impl Fn() -> Result<SyncReport>) -> Result<SyncReport> {
        if db::meta_get(&self.lock().conn, REPLACE)?.is_none() {
            return run();
        }
        {
            let mut inner = self.lock();
            let tx = inner
                .conn
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            if db::meta_get(&tx, KEPT_AT)?.is_none() {
                tx.execute_batch(
                    "DELETE FROM kept; INSERT INTO kept (kind, id, field, value) SELECT kind, id, field, value FROM fields;",
                )?;
                db::meta_set(&tx, KEPT_AT, &Self::registers_mark(&tx)?)?;
            }
            tx.commit()?;
        }
        let first = match run() {
            Ok(report) => report,
            Err(e) => {
                // Nothing was taken in and nothing was edited: the next attempt
                // remembers anew, with whatever is edited until then.
                let inner = self.lock();
                if db::meta_get(&inner.conn, KEPT_AT)? == Some(Self::registers_mark(&inner.conn)?) {
                    inner.conn.execute("DELETE FROM kept", [])?;
                    db::meta_del(&inner.conn, KEPT_AT)?;
                }
                return Err(e);
            }
        };
        self.put_back()?;
        let second = run()?;
        Ok(SyncReport {
            pulled: first.pulled + second.pulled,
            pushed: first.pushed + second.pushed,
            blobs_uploaded: first.blobs_uploaded + second.blobs_uploaded,
            blobs_downloaded: first.blobs_downloaded + second.blobs_downloaded,
        })
    }

    /// S38: gives every register the value this device remembered, under a new
    /// stamp, and sends what it did not have to the trash.
    fn put_back(&self) -> Result<()> {
        self.write(|w| {
            let rows: Vec<(String, String, String, Option<String>)> = {
                let mut stmt = w.tx.prepare(
                    "SELECT f.kind, f.id, f.field, k.value FROM fields f
                     LEFT JOIN kept k ON k.kind = f.kind AND k.id = f.id AND k.field = f.field
                     ORDER BY f.kind, f.id, f.field",
                )?;
                let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?;
                rows.collect::<rusqlite::Result<_>>()?
            };
            let known: BTreeSet<(String, String)> = {
                let mut stmt = w.tx.prepare("SELECT DISTINCT kind, id FROM kept")?;
                let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
                rows.collect::<rusqlite::Result<_>>()?
            };
            // What has a trash to go to; the inbox and the shared settings cannot be deleted.
            let has_trash = |kind: &str, id: &str| match kind {
                KIND_TASK | KIND_ATTACHMENT | KIND_FILTER => true,
                KIND_LIST => id != INBOX_ID,
                _ => false,
            };
            let mut gone: BTreeSet<(String, String)> = BTreeSet::new();
            for (kind, id, field, kept) in rows {
                match kept {
                    Some(value) => {
                        let value = serde_json::from_str(&value).unwrap_or(serde_json::Value::Null);
                        w.set(&kind, &id, &field, value)?;
                    }
                    None if !known.contains(&(kind.clone(), id.clone())) && has_trash(&kind, &id) => {
                        gone.insert((kind, id));
                    }
                    None => w.set(&kind, &id, &field, serde_json::Value::Null)?,
                }
            }
            for (kind, id) in gone {
                w.set(&kind, &id, "deleted", serde_json::Value::Bool(true))?;
            }
            w.tx.execute("DELETE FROM kept", [])?;
            db::meta_del(w.tx, REPLACE)?;
            db::meta_del(w.tx, KEPT_AT)
        })
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

    /// The configured file storage; `None` when sync is off or goes through CalDAV.
    fn file_storage(&self) -> Result<Option<Box<dyn Remote>>> {
        Ok(match self.sync_config()? {
            SyncConfig::Off | SyncConfig::CalDav { .. } => None,
            SyncConfig::Folder { path } => Some(Box::new(DirRemote::new(path))),
            SyncConfig::WebDav { url, user } => Some(Box::new(WebDavRemote::new(&url, &user, &self.password(&user)?)?)),
        })
    }

    /// Runs the configured kind of sync; `None` when sync is off.
    fn run_configured(&self) -> Result<Option<SyncReport>> {
        let config = self.sync_config()?;
        Ok(Some(match config {
            SyncConfig::Off => return Ok(None),
            SyncConfig::Folder { .. } | SyncConfig::WebDav { .. } => {
                let Some(remote) = self.file_storage()? else {
                    return Ok(None);
                };
                let report = self.sync_with(remote.as_ref())?;
                if matches!(config, SyncConfig::Folder { .. }) {
                    // What this run wrote is not news to it.
                    self.folder_changed();
                }
                report
            }
            SyncConfig::CalDav { url, user } => {
                let _running = self.sync_lock.lock().unwrap_or_else(|p| p.into_inner());
                let password = self.password(&user)?;
                self.replacing(|| crate::caldav::engine::run(self, &url, &user, &password))?
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

/// Tests sync settings before they are saved: asks the storage at `config`
/// with `password` and writes nothing, neither there nor here (S26, C26).
#[uniffi::export]
pub fn check_sync_connection(config: SyncConfig, password: String) -> Result<ConnectionCheck> {
    match config {
        SyncConfig::WebDav { url, user } => WebDavRemote::new(&url, &user, &password)?.check(),
        SyncConfig::CalDav { url, user } => {
            crate::caldav::client::Client::check(&url, &user, &password).map(|()| ConnectionCheck::Ready)
        }
        SyncConfig::Off | SyncConfig::Folder { .. } => {
            Err(AppError::invalid("only WebDAV and CalDAV settings can be tested"))
        }
    }
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
             DELETE FROM caldav_calendars; DELETE FROM caldav_items; DELETE FROM kept;
             DELETE FROM meta WHERE key IN ('sync_ok', 'sync_error', 'caldav_filters_sent', 'caldav_home', 'push_published',
                                            'replace_remote', 'replace_kept_at');
             UPDATE fields SET dirty = 1;",
        )?;
        db::meta_set(&tx, "force_snapshot", "1")?;
        tx.commit()?;
        Ok(())
    }

    /// S36: whether both this device and the storage at `config` hold data, so
    /// that the person has a side to choose. Only reads, here and there.
    pub fn sync_conflict(&self, config: SyncConfig, password: String) -> Result<bool> {
        let local: bool = self.lock().conn.query_row(
            "SELECT EXISTS (SELECT 1 FROM tasks WHERE deleted = 0 AND purged = 0)
                 OR EXISTS (SELECT 1 FROM lists WHERE deleted = 0 AND id != ?1)",
            [INBOX_ID],
            |r| r.get(0),
        )?;
        if !local {
            return Ok(false);
        }
        let files = |remote: &dyn Remote| -> Result<bool> {
            for dir in ["log", "snap"] {
                let names = remote.list(&format!("{ROOT}/{dir}"))?;
                if names.iter().any(|name| parse_name(name, DATA).is_some()) {
                    return Ok(true);
                }
            }
            Ok(false)
        };
        match config {
            SyncConfig::Off => Ok(false),
            SyncConfig::Folder { path } => files(&DirRemote::new(path)),
            SyncConfig::WebDav { url, user } => files(&WebDavRemote::new(&url, &user, &password)?),
            SyncConfig::CalDav { url, user } => crate::caldav::engine::holds_objects(&url, &user, &password),
        }
    }

    /// S37: drops what this device holds and makes it a new device, so that the
    /// next run reads the storage from the start. Changes not uploaded yet are
    /// lost; attachment content on disk stays.
    pub fn replace_local_with_remote(&self) -> Result<()> {
        let _running = self.sync_lock.lock().unwrap_or_else(|p| p.into_inner());
        let mut inner = self.lock();
        let inner = &mut *inner;
        let last = db::max_stamp(&inner.conn)?;
        let device = new_device_id();
        let tx = inner
            .conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        tx.execute_batch(
            "DELETE FROM fields; DELETE FROM kept;
             DELETE FROM tasks; DELETE FROM task_tags; DELETE FROM attachments; DELETE FROM filters; DELETE FROM lists;
             INSERT INTO lists (id) VALUES ('inbox');
             DELETE FROM peers; DELETE FROM outbox; DELETE FROM blobs_uploaded;
             DELETE FROM caldav_calendars; DELETE FROM caldav_items;
             DELETE FROM meta WHERE key IN ('sync_ok', 'sync_error', 'caldav_filters_sent', 'caldav_home', 'push_published',
                                            'own_seq', 'force_snapshot', 'replace_remote', 'replace_kept_at');",
        )?;
        db::meta_set(&tx, "device", &device)?;
        tx.commit()?;
        // The clock stays ahead of every stamp this device has issued.
        inner.clock = Clock::new(&device, last.as_deref());
        *self.storage_seen.lock().unwrap_or_else(|p| p.into_inner()) = None;
        *self.folder_seen.lock().unwrap_or_else(|p| p.into_inner()) = None;
        Ok(())
    }

    /// S38: asks the next run to put the data of this device over what the
    /// storage and the other devices hold. Until a run gets through, the
    /// request waits (S39).
    pub fn replace_remote_with_local(&self) -> Result<()> {
        let inner = self.lock();
        inner.conn.execute("DELETE FROM kept", [])?;
        db::meta_del(&inner.conn, KEPT_AT)?;
        db::meta_set(&inner.conn, REPLACE, "1")
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
                // A run that got through may still have left something unread (C23).
                match crate::caldav::engine::unreadable(&inner.conn)? {
                    Some(problem) => db::meta_set(&inner.conn, "sync_error", &problem)?,
                    None => db::meta_del(&inner.conn, "sync_error")?,
                }
            }
            Err(e) => db::meta_set(&inner.conn, "sync_error", &e.to_string())?,
        }
        result
    }

    /// S34: moves attachment content after a run of `sync_now`: uploads what
    /// the storage lacks and downloads what this device lacks. A file that
    /// fails stays waiting and does not fail the call. Does nothing with
    /// CalDAV, where the content travels inside the task, and while another
    /// pass is going.
    pub fn sync_attachments(&self) -> Result<AttachmentReport> {
        match self.file_storage()? {
            Some(remote) => self.sync_attachments_with(remote.as_ref()),
            None => Ok(AttachmentReport::default()),
        }
    }

    /// S35: downloads the content of one attachment now, ahead of the pass.
    pub fn fetch_attachment(&self, id: String) -> Result<Attachment> {
        let found = |store: &Store| -> Result<Attachment> {
            let task: Option<String> = store
                .lock()
                .conn
                .query_row(
                    "SELECT task_id FROM attachments WHERE id = ?1 AND deleted = 0",
                    [&id],
                    |r| r.get(0),
                )
                .optional()?;
            let all = match task {
                Some(task) => store.attachments(task)?,
                None => vec![],
            };
            all.into_iter()
                .find(|a| a.id == id)
                .ok_or_else(|| AppError::not_found("attachment"))
        };
        let attachment = found(self)?;
        if attachment.local_path.is_some() {
            return Ok(attachment);
        }
        if !is_sha256(&attachment.sha256) {
            return Err(AppError::sync("the attachment has no content to download"));
        }
        let Some(remote) = self.file_storage()? else {
            return Err(AppError::sync("the content of this attachment is not in the storage"));
        };
        if !self.download_blob(remote.as_ref(), &attachment.sha256)? {
            return Err(AppError::sync(
                "the content of this attachment has not reached the storage yet",
            ));
        }
        found(self)
    }

    pub fn sync_status(&self) -> Result<SyncStatus> {
        let config = self.sync_config()?;
        let configured = config != SyncConfig::Off;
        let files = matches!(config, SyncConfig::Folder { .. } | SyncConfig::WebDav { .. });
        let attachments_waiting = if files { self.blobs_waiting()? } else { 0 };
        let inner = self.lock();
        let pending: u32 = inner.conn.query_row(
            "SELECT (SELECT count(*) FROM fields WHERE dirty = 1) + (SELECT coalesce(sum(changes), 0) FROM outbox)",
            [],
            |r| r.get(0),
        )?;
        Ok(SyncStatus {
            configured,
            pending: if configured { pending } else { 0 },
            attachments_waiting,
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
