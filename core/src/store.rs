//! The object the apps talk to. Every public method is synchronous and safe
//! to call from any thread; apps call them off the main thread.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use chrono::{NaiveDate, NaiveDateTime};
use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Row};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::db::{self, Change, Touched, KIND_ATTACHMENT, KIND_FILTER, KIND_LIST, KIND_TASK};
use crate::error::{AppError, Result};
use crate::hlc::{Clock, DEVICE_ID_LEN};
use crate::model::*;
use crate::recur::DATE_FMT;
use crate::{order, quickadd, recur};

const MOMENT_FMT: &str = "%Y-%m-%dT%H:%M";

pub(crate) struct Inner {
    pub conn: Connection,
    pub clock: Clock,
    /// Fixed "now" for tests; the wall clock otherwise.
    pub now: Option<NaiveDateTime>,
}

#[derive(uniffi::Object)]
pub struct Store {
    pub(crate) inner: Mutex<Inner>,
    /// Serialises sync runs without blocking local edits during network calls.
    pub(crate) sync_lock: Mutex<()>,
    pub(crate) dir: PathBuf,
    pub(crate) compact_after: Mutex<u32>,
    pub(crate) sync_password: Mutex<Option<String>>,
    /// The storage this process has already checked the format of and listed the snapshots of.
    pub(crate) storage_seen: Mutex<Option<String>>,
    /// Names in the log of the sync folder when it was last looked at.
    pub(crate) folder_seen: Mutex<Option<Vec<String>>>,
    /// How many objects CalDAV sync has built for upload or comparison.
    pub(crate) caldav_renders: AtomicU64,
}

/// One local write transaction: stamps and records field changes, then
/// rebuilds the derived rows before commit.
pub(crate) struct Writer<'a> {
    pub tx: &'a Connection,
    clock: &'a mut Clock,
    now_ms: u64,
    pub now: NaiveDateTime,
    touched: Touched,
}

impl Writer<'_> {
    pub fn set(&mut self, kind: &str, id: &str, field: &str, value: Value) -> Result<()> {
        let change = Change {
            kind: kind.into(),
            id: id.into(),
            field: field.into(),
            value,
            stamp: self.clock.tick(self.now_ms),
        };
        db::apply(self.tx, &change, true, &mut self.touched)?;
        Ok(())
    }
    pub(crate) fn task(&mut self, id: &str, field: &str, value: Value) -> Result<()> {
        self.set(KIND_TASK, id, field, value)
    }
    pub(crate) fn list(&mut self, id: &str, field: &str, value: Value) -> Result<()> {
        self.set(KIND_LIST, id, field, value)
    }
    /// Makes pending changes visible to queries inside the same transaction.
    pub(crate) fn flush(&mut self) -> Result<()> {
        let touched = std::mem::take(&mut self.touched);
        db::settle(self.tx, &touched)
    }
    fn today(&self) -> NaiveDate {
        self.now.date()
    }
    pub(crate) fn moment(&self) -> String {
        self.now.format(MOMENT_FMT).to_string()
    }
}

impl Inner {
    pub fn now(&self) -> NaiveDateTime {
        self.now.unwrap_or_else(|| chrono::Local::now().naive_local())
    }

    pub fn write<T>(&mut self, f: impl FnOnce(&mut Writer) -> Result<T>) -> Result<T> {
        let now = self.now();
        let now_ms = match self.now {
            Some(fixed) => fixed.and_utc().timestamp_millis().max(0) as u64,
            None => chrono::Utc::now().timestamp_millis().max(0) as u64,
        };
        let tx = self
            .conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let out = {
            let mut w = Writer {
                tx: &tx,
                clock: &mut self.clock,
                now_ms,
                now,
                touched: Touched::new(),
            };
            let out = f(&mut w)?;
            w.flush()?;
            out
        };
        tx.commit()?;
        Ok(out)
    }
}

const TASK_COLUMNS: &str = "
    t.id, t.eff_list, t.eff_parent,
    (SELECT p.title FROM tasks p WHERE p.id = t.eff_parent),
    t.title, t.notes, t.start, t.due, t.priority, t.repeat, t.remind, t.done, t.deleted,
    t.log_of IS NOT NULL,
    t.project,
    (SELECT count(*) FROM tasks c WHERE c.eff_parent = t.id AND c.deleted = 0 AND c.purged = 0),
    (SELECT count(*) FROM tasks c WHERE c.eff_parent = t.id AND c.deleted = 0 AND c.purged = 0 AND c.done IS NOT NULL),
    (SELECT count(*) FROM attachments a WHERE a.task_id = t.id AND a.deleted = 0),
    (SELECT group_concat(tag, char(31)) FROM (SELECT tag FROM task_tags WHERE task_id = t.id ORDER BY tag))";

/// Visible, not a completion record.
const LIVE: &str = "t.eff_deleted = 0 AND t.log_of IS NULL";
const NOT_ARCHIVED: &str = "t.eff_list NOT IN (SELECT id FROM lists WHERE archived = 1)";

fn task_from_row(r: &Row) -> rusqlite::Result<TaskItem> {
    let repeat: Option<String> = r.get(9)?;
    let tags: Option<String> = r.get(18)?;
    Ok(TaskItem {
        id: r.get(0)?,
        list_id: r.get(1)?,
        parent_id: r.get(2)?,
        parent_title: r.get(3)?,
        title: r.get(4)?,
        notes: r.get(5)?,
        start: r.get(6)?,
        due: r.get(7)?,
        priority: Priority::from_i64(r.get(8)?),
        repeat: repeat.and_then(|s| serde_json::from_str(&s).ok()),
        remind: r.get(10)?,
        done: r.get(11)?,
        deleted: r.get(12)?,
        is_log: r.get(13)?,
        is_project: r.get(14)?,
        subtasks_total: r.get(15)?,
        subtasks_done: r.get(16)?,
        attachments: r.get(17)?,
        tags: tags
            .map(|t| t.split('\u{1f}').map(str::to_string).collect())
            .unwrap_or_default(),
    })
}

fn query_tasks(conn: &Connection, tail: &str, args: &[&str]) -> Result<Vec<TaskItem>> {
    let sql = format!("SELECT {TASK_COLUMNS} FROM tasks t {tail}");
    let mut stmt = conn.prepare_cached(&sql)?;
    let rows = stmt.query_map(params_from_iter(args.iter()), task_from_row)?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

fn get_task(conn: &Connection, id: &str) -> Result<TaskItem> {
    query_tasks(conn, "WHERE t.id = ?1 AND t.purged = 0", &[id])?
        .pop()
        .ok_or_else(|| AppError::not_found(format!("task {id}")))
}

fn list_from_row(r: &Row) -> rusqlite::Result<TaskList> {
    Ok(TaskList {
        id: r.get(0)?,
        name: r.get(1)?,
        color: r.get(2)?,
        icon: r.get(3)?,
        sort: SortMode::parse(&r.get::<_, String>(4)?),
        show_done: r.get(5)?,
        default_priority: Priority::from_i64(r.get(6)?),
        default_due_today: r.get(7)?,
        archived: r.get(8)?,
        open_count: r.get(9)?,
    })
}

const LIST_COLUMNS: &str = "
    l.id, l.name, l.color, l.icon, l.sort, l.show_done, l.default_priority, l.default_due, l.archived,
    (SELECT count(*) FROM tasks t WHERE t.eff_list = l.id AND t.eff_parent IS NULL AND t.done IS NULL
        AND t.eff_deleted = 0 AND t.log_of IS NULL)";

fn get_list(conn: &Connection, id: &str) -> Result<TaskList> {
    conn.query_row(
        &format!("SELECT {LIST_COLUMNS} FROM lists l WHERE l.id = ?1 AND l.deleted = 0"),
        [id],
        list_from_row,
    )
    .optional()?
    .ok_or_else(|| AppError::not_found(format!("list {id}")))
}

fn new_id() -> String {
    Uuid::now_v7().to_string()
}

fn last_pos(conn: &Connection, sql: &str, args: &[&str]) -> Result<Option<String>> {
    Ok(conn.query_row(sql, params_from_iter(args.iter()), |r| r.get(0))?)
}

pub(crate) fn append_pos_in_list(conn: &Connection, list: &str) -> Result<String> {
    let last = last_pos(
        conn,
        "SELECT max(pos) FROM tasks WHERE eff_list = ?1 AND eff_parent IS NULL",
        &[list],
    )?;
    Ok(order::between(last.as_deref(), None))
}

fn append_pos_in_parent(conn: &Connection, parent: &str) -> Result<String> {
    let last = last_pos(conn, "SELECT max(pos) FROM tasks WHERE eff_parent = ?1", &[parent])?;
    Ok(order::between(last.as_deref(), None))
}

fn descendants(conn: &Connection, id: &str) -> Result<Vec<String>> {
    let mut stmt = conn.prepare_cached(
        "WITH RECURSIVE sub (id) AS (
            SELECT id FROM tasks WHERE eff_parent = ?1
            UNION ALL
            SELECT t.id FROM tasks t JOIN sub ON t.eff_parent = sub.id
         ) SELECT id FROM sub",
    )?;
    let rows = stmt.query_map([id], |r| r.get(0))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

fn opt(value: Option<String>) -> Value {
    value.filter(|v| !v.is_empty()).map_or(Value::Null, Value::String)
}

fn valid_moment(value: &Option<String>) -> Result<()> {
    match value.as_deref() {
        None | Some("") => Ok(()),
        Some(v) if v.len() == 10 && recur::split(v).is_some() => Ok(()),
        Some(v) if NaiveDateTime::parse_from_str(v, MOMENT_FMT).is_ok() => Ok(()),
        Some(v) => Err(AppError::invalid(format!("bad date: {v}"))),
    }
}

fn clean_tag(tag: &str) -> String {
    tag.trim().trim_start_matches('#').to_lowercase()
}

pub(crate) fn guess_mime(name: &str) -> &'static str {
    let ext = name
        .rsplit_once('.')
        .map(|(_, e)| e.to_ascii_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "heic" => "image/heic",
        "svg" => "image/svg+xml",
        "pdf" => "application/pdf",
        "txt" | "md" | "log" => "text/plain",
        "html" | "htm" => "text/html",
        "json" => "application/json",
        "zip" => "application/zip",
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        _ => "application/octet-stream",
    }
}

impl Store {
    pub(crate) fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub(crate) fn write<T>(&self, f: impl FnOnce(&mut Writer) -> Result<T>) -> Result<T> {
        self.lock().write(f)
    }

    pub(crate) fn blob_path(&self, sha256: &str) -> PathBuf {
        self.dir.join("blobs").join(sha256)
    }

    /// Pins "now" so tests can reason about dates.
    #[doc(hidden)]
    pub fn set_now_for_tests(&self, now: &str) {
        self.lock().now = NaiveDateTime::parse_from_str(now, MOMENT_FMT).ok();
    }

    #[doc(hidden)]
    pub fn set_compact_after_for_tests(&self, files: u32) {
        *self.compact_after.lock().unwrap() = files;
    }

    #[doc(hidden)]
    pub fn caldav_renders_for_tests(&self) -> u64 {
        self.caldav_renders.load(Ordering::Relaxed)
    }

    #[doc(hidden)]
    pub fn data_dir(&self) -> &Path {
        &self.dir
    }
}

#[uniffi::export]
impl Store {
    /// Opens (creating if needed) the database in `dir`.
    #[uniffi::constructor]
    pub fn open(dir: String) -> Result<Arc<Store>> {
        let dir = PathBuf::from(dir);
        std::fs::create_dir_all(dir.join("blobs"))?;
        let conn = Connection::open(dir.join("lists.sqlite"))?;
        db::migrate(&conn)?;
        let device = match db::meta_get(&conn, "device")? {
            Some(d) => d,
            None => {
                let simple = Uuid::now_v7().simple().to_string();
                let d = simple[simple.len() - DEVICE_ID_LEN..].to_string();
                db::meta_set(&conn, "device", &d)?;
                d
            }
        };
        let clock = Clock::new(&device, db::max_stamp(&conn)?.as_deref());
        Ok(Arc::new(Store {
            inner: Mutex::new(Inner { conn, clock, now: None }),
            sync_lock: Mutex::new(()),
            dir,
            compact_after: Mutex::new(64),
            sync_password: Mutex::new(None),
            storage_seen: Mutex::new(None),
            folder_seen: Mutex::new(None),
            caldav_renders: AtomicU64::new(0),
        }))
    }

    pub fn device_id(&self) -> String {
        self.lock().clock.device().to_string()
    }

    // ---- lists ----

    /// Inbox first, then the user's lists in their order. Archived lists are included.
    pub fn lists(&self) -> Result<Vec<TaskList>> {
        let inner = self.lock();
        let mut stmt = inner.conn.prepare_cached(&format!(
            "SELECT {LIST_COLUMNS} FROM lists l WHERE l.deleted = 0 ORDER BY l.id != 'inbox', l.pos, l.id"
        ))?;
        let rows = stmt.query_map([], list_from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn list(&self, id: String) -> Result<TaskList> {
        get_list(&self.lock().conn, &id)
    }

    pub fn create_list(&self, name: String) -> Result<TaskList> {
        let name = name.trim().to_string();
        if name.is_empty() {
            return Err(AppError::invalid("list name is empty"));
        }
        self.write(|w| {
            let id = new_id();
            let last = last_pos(w.tx, "SELECT max(pos) FROM lists WHERE id != 'inbox'", &[])?;
            w.list(&id, "name", json!(name))?;
            w.list(&id, "pos", json!(order::between(last.as_deref(), None)))?;
            w.flush()?;
            get_list(w.tx, &id)
        })
    }

    pub fn rename_list(&self, id: String, name: String) -> Result<()> {
        let name = name.trim().to_string();
        if name.is_empty() {
            return Err(AppError::invalid("list name is empty"));
        }
        self.list_field(id, "name", json!(name))
    }

    pub fn set_list_color(&self, id: String, color: String) -> Result<()> {
        self.list_field(id, "color", json!(color))
    }

    pub fn set_list_icon(&self, id: String, icon: String) -> Result<()> {
        self.list_field(id, "icon", json!(icon))
    }

    pub fn set_list_sort(&self, id: String, sort: SortMode) -> Result<()> {
        self.list_field(id, "sort", json!(sort.as_str()))
    }

    pub fn set_list_show_done(&self, id: String, show: bool) -> Result<()> {
        self.list_field(id, "show_done", json!(show))
    }

    pub fn set_list_defaults(&self, id: String, priority: Priority, due_today: bool) -> Result<()> {
        self.write(|w| {
            get_list(w.tx, &id)?;
            w.list(&id, "default_priority", json!(priority.as_i64()))?;
            w.list(&id, "default_due", json!(due_today))
        })
    }

    pub fn set_list_archived(&self, id: String, archived: bool) -> Result<()> {
        if id == INBOX_ID {
            return Err(AppError::invalid("the inbox cannot be archived"));
        }
        self.list_field(id, "archived", json!(archived))
    }

    /// Places the list right after `after`, or first among the user's lists.
    pub fn move_list(&self, id: String, after: Option<String>) -> Result<()> {
        if id == INBOX_ID {
            return Err(AppError::invalid("the inbox cannot be moved"));
        }
        self.write(|w| {
            get_list(w.tx, &id)?;
            let mut stmt = w.tx.prepare(
                "SELECT id, pos FROM lists WHERE deleted = 0 AND id != 'inbox' AND id != ?1 ORDER BY pos, id",
            )?;
            let siblings: Vec<(String, String)> = stmt
                .query_map([&id], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<rusqlite::Result<_>>()?;
            drop(stmt);
            let pos = pos_after(&siblings, after.as_deref());
            w.list(&id, "pos", json!(pos))
        })
    }

    /// Deletes the list and moves its tasks to the trash.
    pub fn delete_list(&self, id: String) -> Result<()> {
        if id == INBOX_ID {
            return Err(AppError::invalid("the inbox cannot be deleted"));
        }
        self.write(|w| {
            get_list(w.tx, &id)?;
            let mut stmt =
                w.tx.prepare("SELECT id FROM tasks WHERE eff_list = ?1 AND eff_parent IS NULL AND deleted = 0")?;
            let tasks: Vec<String> = stmt.query_map([&id], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
            drop(stmt);
            for task in tasks {
                w.task(&task, "deleted", json!(true))?;
            }
            w.list(&id, "deleted", json!(true))
        })
    }

    // ---- queries ----

    pub fn tasks(&self, view: Scope) -> Result<Vec<TaskItem>> {
        let inner = self.lock();
        let today = inner.now().date().format(DATE_FMT).to_string();
        let conn = &inner.conn;
        match view {
            Scope::Inbox => list_tasks(conn, INBOX_ID),
            Scope::List { id } => list_tasks(conn, &id),
            Scope::Today => query_tasks(
                conn,
                &format!(
                    "WHERE {LIVE} AND {NOT_ARCHIVED} AND t.done IS NULL
                       AND substr(coalesce(t.due, t.start), 1, 10) <= ?1
                       AND (t.start IS NULL OR substr(t.start, 1, 10) <= ?1)
                     ORDER BY coalesce(t.due, t.start), t.priority DESC, t.pos, t.id"
                ),
                &[&today],
            ),
            Scope::Upcoming => query_tasks(
                conn,
                &format!(
                    "WHERE {LIVE} AND {NOT_ARCHIVED} AND t.done IS NULL
                       AND (substr(coalesce(t.due, t.start), 1, 10) > ?1
                            OR (t.start IS NOT NULL AND substr(t.start, 1, 10) > ?1))
                     ORDER BY coalesce(t.due, t.start), t.priority DESC, t.pos, t.id"
                ),
                &[&today],
            ),
            Scope::All => query_tasks(
                conn,
                &format!(
                    "WHERE {LIVE} AND {NOT_ARCHIVED} AND t.done IS NULL AND t.eff_parent IS NULL
                     ORDER BY t.eff_list != 'inbox', (SELECT pos FROM lists WHERE id = t.eff_list), t.eff_list, t.pos, t.id"
                ),
                &[],
            ),
            Scope::Completed => query_tasks(
                conn,
                "WHERE t.eff_deleted = 0 AND t.done IS NOT NULL AND (t.eff_parent IS NULL OR t.log_of IS NOT NULL)
                 ORDER BY t.done DESC, t.id LIMIT 500",
                &[],
            ),
            Scope::Trash => query_tasks(conn, "WHERE t.deleted = 1 AND t.purged = 0 ORDER BY t.title, t.id", &[]),
            Scope::Tag { name } => query_tasks(
                conn,
                &format!(
                    "WHERE {LIVE} AND {NOT_ARCHIVED} AND t.done IS NULL
                       AND EXISTS (SELECT 1 FROM task_tags g WHERE g.task_id = t.id AND g.tag = ?1)
                     ORDER BY t.priority DESC, coalesce(t.due, t.start) IS NULL, coalesce(t.due, t.start), t.pos, t.id"
                ),
                &[&clean_tag(&name)],
            ),
            Scope::Project { id } => query_tasks(
                conn,
                "WHERE t.eff_parent = ?1 AND t.deleted = 0 AND t.purged = 0 ORDER BY t.done IS NOT NULL, t.pos, t.id",
                &[&id],
            ),
            Scope::Filter { id } => {
                let spec: String = conn
                    .query_row("SELECT spec FROM filters WHERE id = ?1 AND deleted = 0", [&id], |r| r.get(0))
                    .optional()?
                    .ok_or_else(|| AppError::not_found(format!("filter {id}")))?;
                filter_tasks(conn, &serde_json::from_str(&spec).unwrap_or_default(), &today)
            }
            Scope::Search { text } => {
                // SQLite's LIKE folds case for ASCII only, so matching is done here.
                let needle = text.trim().to_lowercase();
                if needle.is_empty() {
                    return Ok(vec![]);
                }
                let all = query_tasks(
                    conn,
                    &format!("WHERE {LIVE} ORDER BY t.done IS NOT NULL, coalesce(t.due, t.start) IS NULL, coalesce(t.due, t.start), t.title"),
                    &[],
                )?;
                Ok(all
                    .into_iter()
                    .filter(|t| t.title.to_lowercase().contains(&needle) || t.notes.to_lowercase().contains(&needle))
                    .take(200)
                    .collect())
            }
        }
    }

    pub fn subtasks(&self, parent_id: String) -> Result<Vec<TaskItem>> {
        query_tasks(
            &self.lock().conn,
            "WHERE t.eff_parent = ?1 AND t.deleted = 0 AND t.purged = 0 ORDER BY t.pos, t.id",
            &[&parent_id],
        )
    }

    pub fn task(&self, id: String) -> Result<TaskItem> {
        get_task(&self.lock().conn, &id)
    }

    /// Open tasks that have a reminder, earliest first. The apps turn these into local notifications.
    pub fn reminders(&self) -> Result<Vec<TaskItem>> {
        query_tasks(
            &self.lock().conn,
            &format!("WHERE {LIVE} AND {NOT_ARCHIVED} AND t.done IS NULL AND t.remind IS NOT NULL ORDER BY t.remind, t.id LIMIT 64"),
            &[],
        )
    }

    /// What to notify about from now on, earliest first: reminders set on
    /// tasks, reminders derived from due dates, and daily summaries for the
    /// coming week. At most 60, which fits what the platforms let an app schedule.
    pub fn planned_notifications(&self, settings: NotifySettings) -> Result<Vec<PlannedNotification>> {
        if !settings.enabled {
            return Ok(vec![]);
        }
        let inner = self.lock();
        let now = inner.now();
        let clock = |value: &Option<String>| {
            value
                .as_deref()
                .and_then(|v| chrono::NaiveTime::parse_from_str(v, "%H:%M").ok())
        };
        let all_day = clock(&settings.all_day_at);
        let moment = |value: &str| NaiveDateTime::parse_from_str(value, MOMENT_FMT).ok();
        let tasks = query_tasks(
            &inner.conn,
            &format!(
                "WHERE {LIVE} AND {NOT_ARCHIVED} AND t.done IS NULL AND (t.remind IS NOT NULL OR t.due IS NOT NULL)"
            ),
            &[],
        )?;
        let mut out = Vec::new();
        for task in &tasks {
            // (kind, moment, what tells notifications of one task apart)
            let planned: Vec<(NotificationKind, NaiveDateTime, String)> = match (&task.remind, &task.due) {
                // A reminder without a time of day follows the all-day setting, nine o'clock failing that.
                (Some(remind), _) => moment(remind)
                    .or_else(|| {
                        recur::split(remind).map(|(d, _)| {
                            d.and_time(
                                all_day.unwrap_or_else(|| chrono::NaiveTime::from_hms_opt(9, 0, 0).expect("valid")),
                            )
                        })
                    })
                    .map(|at| (NotificationKind::Reminder, at, String::new()))
                    .into_iter()
                    .collect(),
                (None, Some(due)) if due.len() > 10 => moment(due)
                    .map(|at| {
                        let mut leads = settings.lead_minutes.clone();
                        leads.sort_unstable();
                        leads.dedup();
                        leads
                            .into_iter()
                            .map(|lead| {
                                (
                                    NotificationKind::Due,
                                    at - chrono::Duration::minutes(i64::from(lead)),
                                    format!(":{lead}"),
                                )
                            })
                            .collect()
                    })
                    .unwrap_or_default(),
                (None, Some(due)) => all_day
                    .and_then(|time| {
                        recur::split(due).map(|(d, _)| (NotificationKind::Due, d.and_time(time), String::new()))
                    })
                    .into_iter()
                    .collect(),
                (None, None) => Vec::new(),
            };
            for (kind, at, suffix) in planned.into_iter().filter(|(_, at, _)| *at > now) {
                out.push(PlannedNotification {
                    key: format!("task:{}{suffix}", task.id),
                    kind,
                    at: at.format(MOMENT_FMT).to_string(),
                    task_id: Some(task.id.clone()),
                    title: task.title.clone(),
                    due: task.due.clone(),
                    count: 0,
                });
            }
        }
        if let Some(time) = clock(&settings.summary_at) {
            for offset in 0..7 {
                let day = now.date() + chrono::Duration::days(offset);
                let at = day.and_time(time);
                let key = day.format(DATE_FMT).to_string();
                // Everything due by that day, as things stand now.
                let count = tasks
                    .iter()
                    .filter(|t| t.due.as_deref().is_some_and(|d| d[..10] <= *key))
                    .count() as u32;
                if at > now && count > 0 {
                    out.push(PlannedNotification {
                        key: format!("summary:{key}"),
                        kind: NotificationKind::Summary,
                        at: at.format(MOMENT_FMT).to_string(),
                        task_id: None,
                        title: String::new(),
                        due: None,
                        count,
                    });
                }
            }
        }
        out.sort_by(|a, b| (&a.at, &a.key).cmp(&(&b.at, &b.key)));
        out.truncate(60);
        Ok(out)
    }

    pub fn tags(&self) -> Result<Vec<TagCount>> {
        let inner = self.lock();
        let mut stmt = inner.conn.prepare_cached(&format!(
            "SELECT g.tag, count(*) FROM task_tags g JOIN tasks t ON t.id = g.task_id
             WHERE {LIVE} AND {NOT_ARCHIVED} AND t.done IS NULL GROUP BY g.tag ORDER BY g.tag"
        ))?;
        let rows = stmt.query_map([], |r| {
            Ok(TagCount {
                name: r.get(0)?,
                open_count: r.get(1)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn counts(&self) -> Result<Counts> {
        let inner = self.lock();
        let today = inner.now().date().format(DATE_FMT).to_string();
        let count = |sql: &str, args: &[&str]| -> Result<u32> {
            Ok(inner.conn.query_row(
                &format!("SELECT count(*) FROM tasks t WHERE {sql}"),
                params_from_iter(args.iter()),
                |r| r.get(0),
            )?)
        };
        let open = format!("{LIVE} AND {NOT_ARCHIVED} AND t.done IS NULL");
        Ok(Counts {
            inbox: count(&format!("{LIVE} AND t.done IS NULL AND t.eff_list = 'inbox' AND t.eff_parent IS NULL"), &[])?,
            today: count(
                &format!("{open} AND substr(coalesce(t.due, t.start), 1, 10) <= ?1 AND (t.start IS NULL OR substr(t.start, 1, 10) <= ?1)"),
                &[&today],
            )?,
            overdue: count(&format!("{open} AND substr(t.due, 1, 10) < ?1"), &[&today])?,
            upcoming: count(
                &format!("{open} AND (substr(coalesce(t.due, t.start), 1, 10) > ?1 OR (t.start IS NOT NULL AND substr(t.start, 1, 10) > ?1))"),
                &[&today],
            )?,
            trash: count("t.deleted = 1 AND t.purged = 0", &[])?,
        })
    }

    // ---- projects ----

    /// Open projects in the order of their lists.
    pub fn projects(&self) -> Result<Vec<TaskItem>> {
        query_tasks(
            &self.lock().conn,
            &format!(
                "WHERE {LIVE} AND {NOT_ARCHIVED} AND t.project = 1 AND t.done IS NULL AND t.eff_parent IS NULL
                 ORDER BY t.eff_list != 'inbox', (SELECT pos FROM lists WHERE id = t.eff_list), t.eff_list, t.pos, t.id"
            ),
            &[],
        )
    }

    /// Turns a top-level task into a project or back. Nothing else about it changes:
    /// a project is a task whose subtasks are shown as a list of their own.
    pub fn set_project(&self, id: String, project: bool) -> Result<()> {
        self.write(|w| {
            let task = get_task(w.tx, &id)?;
            if project && task.parent_id.is_some() {
                return Err(AppError::invalid("only a top-level task can be a project"));
            }
            w.task(&id, "project", json!(project))
        })
    }

    /// Creates a task inside a project (or under any task) from one line of text.
    pub fn quick_add_under(&self, text: String, parent_id: String) -> Result<TaskItem> {
        self.write(|w| {
            let parsed = quickadd::parse(&text, w.today());
            // A list named in the line makes no sense here: the parent decides the list.
            let title = match parsed.list_name {
                Some(name) => format!("{} @{name}", parsed.title).trim().to_string(),
                None => parsed.title,
            };
            create_task(
                w,
                NewTask {
                    title,
                    parent_id: Some(parent_id),
                    due: parsed.due,
                    priority: (parsed.priority != Priority::None).then_some(parsed.priority),
                    tags: parsed.tags,
                    ..NewTask::default()
                },
            )
        })
    }

    // ---- saved filters ----

    pub fn filters(&self) -> Result<Vec<SavedFilter>> {
        let inner = self.lock();
        let today = inner.now().date().format(DATE_FMT).to_string();
        let mut stmt = inner
            .conn
            .prepare_cached("SELECT id, name, spec FROM filters WHERE deleted = 0 ORDER BY pos, id")?;
        let rows: Vec<(String, String, String)> = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
            .collect::<rusqlite::Result<_>>()?;
        rows.into_iter()
            .map(|(id, name, spec)| {
                let spec: FilterSpec = serde_json::from_str(&spec).unwrap_or_default();
                let open_count = filter_tasks(&inner.conn, &spec, &today)?
                    .iter()
                    .filter(|t| t.done.is_none())
                    .count() as u32;
                Ok(SavedFilter {
                    id,
                    name,
                    spec,
                    open_count,
                })
            })
            .collect()
    }

    /// What a filter would show, without saving it.
    pub fn preview_filter(&self, spec: FilterSpec) -> Result<Vec<TaskItem>> {
        let inner = self.lock();
        let today = inner.now().date().format(DATE_FMT).to_string();
        filter_tasks(&inner.conn, &spec, &today)
    }

    pub fn create_filter(&self, name: String, spec: FilterSpec) -> Result<SavedFilter> {
        let name = name.trim().to_string();
        if name.is_empty() {
            return Err(AppError::invalid("filter name is empty"));
        }
        let id = self.write(|w| {
            let id = new_id();
            let last = last_pos(w.tx, "SELECT max(pos) FROM filters", &[])?;
            w.set(KIND_FILTER, &id, "name", json!(name))?;
            w.set(KIND_FILTER, &id, "spec", serde_json::to_value(&spec)?)?;
            w.set(KIND_FILTER, &id, "pos", json!(order::between(last.as_deref(), None)))?;
            Ok(id)
        })?;
        self.filters()?
            .into_iter()
            .find(|f| f.id == id)
            .ok_or_else(|| AppError::not_found("filter"))
    }

    pub fn update_filter(&self, id: String, name: String, spec: FilterSpec) -> Result<()> {
        let name = name.trim().to_string();
        if name.is_empty() {
            return Err(AppError::invalid("filter name is empty"));
        }
        self.write(|w| {
            let (old_name, old_spec): (String, String) =
                w.tx.query_row(
                    "SELECT name, spec FROM filters WHERE id = ?1 AND deleted = 0",
                    [&id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?
                .ok_or_else(|| AppError::not_found(format!("filter {id}")))?;
            if old_name != name {
                w.set(KIND_FILTER, &id, "name", json!(name))?;
            }
            if serde_json::from_str::<FilterSpec>(&old_spec).ok().as_ref() != Some(&spec) {
                w.set(KIND_FILTER, &id, "spec", serde_json::to_value(&spec)?)?;
            }
            Ok(())
        })
    }

    pub fn delete_filter(&self, id: String) -> Result<()> {
        self.write(|w| w.set(KIND_FILTER, &id, "deleted", json!(true)))
    }

    // ---- creating ----

    pub fn create_task(&self, new: NewTask) -> Result<TaskItem> {
        self.write(|w| create_task(w, new))
    }

    pub fn parse_quick(&self, text: String) -> QuickParse {
        let today = self.lock().now().date();
        quickadd::parse(&text, today)
    }

    /// Creates a task from one line of text. `list_id` is used unless the line names a list.
    pub fn quick_add(&self, text: String, list_id: Option<String>) -> Result<TaskItem> {
        self.write(|w| {
            let parsed = quickadd::parse(&text, w.today());
            let mut title = parsed.title;
            let mut list = list_id;
            if let Some(name) = parsed.list_name {
                match find_list_by_name(w.tx, &name)? {
                    Some(id) => list = Some(id),
                    // Not a list after all: keep the word in the title.
                    None => title = format!("{title} @{name}").trim().to_string(),
                }
            }
            create_task(
                w,
                NewTask {
                    title,
                    list_id: list,
                    due: parsed.due,
                    priority: (parsed.priority != Priority::None).then_some(parsed.priority),
                    tags: parsed.tags,
                    ..NewTask::default()
                },
            )
        })
    }

    /// Copies a task with its subtasks and attachments, placing the copy right after it.
    pub fn duplicate_task(&self, id: String) -> Result<TaskItem> {
        self.write(|w| {
            let original = get_task(w.tx, &id)?;
            let copy = duplicate(w, &original, original.parent_id.clone())?;
            w.flush()?;
            place_after(w, &copy, &original)?;
            w.flush()?;
            get_task(w.tx, &copy)
        })
    }

    // ---- editing ----

    pub fn set_title(&self, id: String, title: String) -> Result<()> {
        let title = title.trim().to_string();
        if title.is_empty() {
            return Err(AppError::invalid("title is empty"));
        }
        self.task_field(id, "title", json!(title))
    }

    pub fn set_notes(&self, id: String, notes: String) -> Result<()> {
        self.task_field(id, "notes", json!(notes))
    }

    pub fn set_start(&self, id: String, start: Option<String>) -> Result<()> {
        valid_moment(&start)?;
        self.task_field(id, "start", opt(start))
    }

    pub fn set_due(&self, id: String, due: Option<String>) -> Result<()> {
        valid_moment(&due)?;
        self.task_field(id, "due", opt(due))
    }

    pub fn set_priority(&self, id: String, priority: Priority) -> Result<()> {
        self.task_field(id, "priority", json!(priority.as_i64()))
    }

    pub fn set_remind(&self, id: String, remind: Option<String>) -> Result<()> {
        valid_moment(&remind)?;
        self.task_field(id, "remind", opt(remind))
    }

    pub fn set_repeat(&self, id: String, repeat: Option<Repeat>) -> Result<()> {
        self.write(|w| {
            let task = get_task(w.tx, &id)?;
            let value = match repeat {
                Some(rule) => {
                    serde_json::to_value(recur::normalized(rule, task.due.as_deref().or(task.start.as_deref())))?
                }
                None => Value::Null,
            };
            w.task(&id, "repeat", value)
        })
    }

    pub fn add_tag(&self, id: String, tag: String) -> Result<()> {
        let tag = clean_tag(&tag);
        if tag.is_empty() || tag.chars().any(char::is_whitespace) {
            return Err(AppError::invalid("a tag is one word"));
        }
        self.task_field(id, &format!("tag:{tag}"), json!(true))
    }

    pub fn remove_tag(&self, id: String, tag: String) -> Result<()> {
        self.task_field(id, &format!("tag:{}", clean_tag(&tag)), json!(false))
    }

    // ---- state ----

    /// Completes the task and its open subtasks. A repeating task moves to
    /// its next occurrence instead and leaves a record in Completed.
    pub fn complete_task(&self, id: String) -> Result<TaskItem> {
        self.write(|w| complete_in(w, &id))
    }

    pub fn reopen_task(&self, id: String) -> Result<()> {
        self.write(|w| {
            if get_task(w.tx, &id)?.is_log {
                return Err(AppError::invalid("a completed occurrence cannot be reopened"));
            }
            w.task(&id, "done", Value::Null)
        })
    }

    pub fn delete_task(&self, id: String) -> Result<()> {
        self.task_field(id, "deleted", json!(true))
    }

    pub fn restore_task(&self, id: String) -> Result<()> {
        self.task_field(id, "deleted", json!(false))
    }

    /// Removes everything in the trash for good. Returns how many tasks were removed.
    pub fn empty_trash(&self) -> Result<u32> {
        self.write(|w| {
            let mut stmt = w.tx.prepare("SELECT id FROM tasks WHERE deleted = 1 AND purged = 0")?;
            let ids: Vec<String> = stmt.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
            drop(stmt);
            for id in &ids {
                w.task(id, "purged", json!(true))?;
            }
            Ok(ids.len() as u32)
        })
    }

    // ---- moving ----

    /// Moves a top-level task (with its subtasks) to the end of another list.
    pub fn move_to_list(&self, id: String, list_id: String) -> Result<()> {
        self.write(|w| {
            get_task(w.tx, &id)?;
            get_list(w.tx, &list_id)?;
            heal_tree(w)?;
            let pos = append_pos_in_list(w.tx, &list_id)?;
            w.task(&id, "parent", Value::Null)?;
            w.task(&id, "list", json!(list_id))?;
            w.task(&id, "pos", json!(pos))
        })
    }

    /// Re-parents and reorders. With a parent the task becomes its subtask;
    /// without one it becomes a top-level task of `list_id` (its current list
    /// when omitted). It is placed right after `after`, or first.
    pub fn move_task(
        &self,
        id: String,
        list_id: Option<String>,
        parent_id: Option<String>,
        after: Option<String>,
    ) -> Result<()> {
        self.write(|w| {
            heal_tree(w)?;
            let task = get_task(w.tx, &id)?;
            let siblings: Vec<(String, String)> = match &parent_id {
                Some(parent) => {
                    if *parent == id || descendants(w.tx, &id)?.contains(parent) {
                        return Err(AppError::invalid("a task cannot be moved into itself"));
                    }
                    get_task(w.tx, parent)?;
                    w.task(&id, "parent", json!(parent))?;
                    sibling_positions(w.tx, "eff_parent = ?1", parent, &id)?
                }
                None => {
                    let list = list_id.unwrap_or(task.list_id);
                    get_list(w.tx, &list)?;
                    w.task(&id, "parent", Value::Null)?;
                    w.task(&id, "list", json!(list))?;
                    sibling_positions(w.tx, "eff_list = ?1 AND eff_parent IS NULL", &list, &id)?
                }
            };
            w.task(&id, "pos", json!(pos_after(&siblings, after.as_deref())))
        })
    }

    // ---- attachments ----

    pub fn attachments(&self, task_id: String) -> Result<Vec<Attachment>> {
        let inner = self.lock();
        let mut stmt = inner.conn.prepare_cached(
            "SELECT id, task_id, name, mime, size, sha256 FROM attachments WHERE task_id = ?1 AND deleted = 0 ORDER BY id",
        )?;
        let rows = stmt.query_map([&task_id], |r| {
            let sha256: String = r.get(5)?;
            let path = self.blob_path(&sha256);
            let present = db::is_sha256(&sha256) && path.exists();
            Ok(Attachment {
                id: r.get(0)?,
                task_id: r.get(1)?,
                name: r.get(2)?,
                mime: r.get(3)?,
                size: r.get(4)?,
                local_path: present.then(|| path.to_string_lossy().into_owned()),
                sha256,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Copies the file at `path` into the store and attaches it to the task.
    pub fn add_attachment(&self, task_id: String, path: String, name: Option<String>) -> Result<Attachment> {
        let source = Path::new(&path);
        let bytes = std::fs::read(source)?;
        let sha256 = hex(&Sha256::digest(&bytes));
        let target = self.blob_path(&sha256);
        if !target.exists() {
            let tmp = target.with_extension("part");
            std::fs::write(&tmp, &bytes)?;
            std::fs::rename(&tmp, &target)?;
        }
        let name = name
            .filter(|n| !n.trim().is_empty())
            .or_else(|| source.file_name().map(|n| n.to_string_lossy().into_owned()))
            .unwrap_or_else(|| "file".into());
        let id = self.write(|w| {
            get_task(w.tx, &task_id)?;
            let id = new_id();
            w.set(KIND_ATTACHMENT, &id, "task", json!(task_id))?;
            w.set(KIND_ATTACHMENT, &id, "name", json!(name))?;
            w.set(KIND_ATTACHMENT, &id, "mime", json!(guess_mime(&name)))?;
            w.set(KIND_ATTACHMENT, &id, "size", json!(bytes.len()))?;
            w.set(KIND_ATTACHMENT, &id, "sha256", json!(sha256))?;
            Ok(id)
        })?;
        self.attachments(task_id)?
            .into_iter()
            .find(|a| a.id == id)
            .ok_or_else(|| AppError::not_found("attachment"))
    }

    pub fn remove_attachment(&self, id: String) -> Result<()> {
        self.write(|w| w.set(KIND_ATTACHMENT, &id, "deleted", json!(true)))
    }
}

impl Store {
    fn task_field(&self, id: String, field: &str, value: Value) -> Result<()> {
        self.write(|w| {
            get_task(w.tx, &id)?;
            w.task(&id, field, value)
        })
    }

    fn list_field(&self, id: String, field: &str, value: Value) -> Result<()> {
        self.write(|w| {
            get_list(w.tx, &id)?;
            w.list(&id, field, value)
        })
    }
}

/// Completes a task inside a write transaction: see `Store::complete_task`.
pub(crate) fn complete_in(w: &mut Writer, id: &str) -> Result<TaskItem> {
    let task = get_task(w.tx, id)?;
    if task.done.is_some() {
        return Ok(task);
    }
    let subtree = descendants(w.tx, id)?;
    let current = task
        .due
        .as_deref()
        .or(task.start.as_deref())
        .and_then(recur::split)
        .map(|(d, _)| d);
    let next = task
        .repeat
        .as_ref()
        .and_then(|rule| recur::next_occurrence(rule, current, w.today()));
    match (next, &task.repeat) {
        (Some(next), Some(rule)) => {
            let from = current.unwrap_or(w.today());
            // Same occurrence, same record: two devices completing it offline agree on the id.
            let log_id = Uuid::new_v5(&Uuid::NAMESPACE_OID, format!("{id}|{from}").as_bytes()).to_string();
            w.task(&log_id, "title", json!(task.title))?;
            w.task(&log_id, "list", json!(task.list_id))?;
            w.task(&log_id, "priority", json!(task.priority.as_i64()))?;
            w.task(&log_id, "due", opt(task.due.clone()))?;
            w.task(&log_id, "done", json!(w.moment()))?;
            w.task(&log_id, "log_of", json!(id))?;

            let delta = (next - from).num_days();
            match (&task.due, &task.start) {
                (None, None) => w.task(id, "due", json!(next.format(DATE_FMT).to_string()))?,
                (due, start) => {
                    if let Some(due) = due {
                        w.task(id, "due", opt(recur::shift(due, delta)))?;
                    }
                    if let Some(start) = start {
                        w.task(id, "start", opt(recur::shift(start, delta)))?;
                    }
                }
            }
            if let Some(remind) = &task.remind {
                w.task(id, "remind", opt(recur::shift(remind, delta)))?;
            }
            if let Some(left) = rule.count {
                let mut rule = rule.clone();
                rule.count = Some(left.saturating_sub(1));
                w.task(id, "repeat", serde_json::to_value(rule)?)?;
            }
            for sub in subtree {
                w.task(&sub, "done", Value::Null)?;
            }
        }
        _ => {
            let moment = w.moment();
            w.task(id, "done", json!(moment))?;
            for sub in subtree {
                let open: bool =
                    w.tx.query_row("SELECT done IS NULL FROM tasks WHERE id = ?1", [&sub], |r| r.get(0))?;
                if open {
                    w.task(&sub, "done", json!(moment))?;
                }
            }
        }
    }
    w.flush()?;
    get_task(w.tx, id)
}

fn list_tasks(conn: &Connection, list_id: &str) -> Result<Vec<TaskItem>> {
    let list = get_list(conn, list_id)?;
    let order = match list.sort {
        SortMode::Manual => "t.pos, t.id",
        SortMode::Due => "coalesce(t.due, t.start) IS NULL, coalesce(t.due, t.start), t.pos, t.id",
        SortMode::Priority => "t.priority DESC, t.pos, t.id",
        SortMode::Title => "t.title COLLATE NOCASE, t.pos, t.id",
    };
    let done = if list.show_done { "" } else { "AND t.done IS NULL" };
    query_tasks(
        conn,
        &format!(
            "WHERE {LIVE} AND t.eff_list = ?1 AND t.eff_parent IS NULL {done} ORDER BY t.done IS NOT NULL, {order}"
        ),
        &[list_id],
    )
}

/// Tasks a filter selects, subtasks included, dated ones first.
fn filter_tasks(conn: &Connection, spec: &FilterSpec, today: &str) -> Result<Vec<TaskItem>> {
    let mut sql = format!("WHERE {LIVE} AND {NOT_ARCHIVED}");
    let mut args: Vec<String> = Vec::new();
    let arg = |value: String, args: &mut Vec<String>| {
        args.push(value);
        format!("?{}", args.len())
    };
    match spec.status {
        FilterStatus::Open => sql.push_str(" AND t.done IS NULL"),
        FilterStatus::Done => sql.push_str(" AND t.done IS NOT NULL"),
        FilterStatus::All => {}
    }
    let date = "substr(coalesce(t.due, t.start), 1, 10)";
    match spec.due {
        DueWindow::Any => {}
        DueWindow::NoDate => sql.push_str(" AND t.due IS NULL AND t.start IS NULL"),
        DueWindow::Overdue => sql.push_str(&format!(
            " AND substr(t.due, 1, 10) < {}",
            arg(today.to_string(), &mut args)
        )),
        DueWindow::Today => sql.push_str(&format!(" AND {date} = {}", arg(today.to_string(), &mut args))),
        DueWindow::Next { days } => {
            let last = recur::shift(today, i64::from(days.clamp(1, 3660)) - 1).unwrap_or_else(|| today.to_string());
            sql.push_str(&format!(" AND {date} <= {}", arg(last, &mut args)));
        }
    }
    if !spec.list_ids.is_empty() {
        let marks: Vec<String> = spec.list_ids.iter().map(|id| arg(id.clone(), &mut args)).collect();
        sql.push_str(&format!(" AND t.eff_list IN ({})", marks.join(", ")));
    }
    for tag in spec.tags.iter().map(|t| clean_tag(t)).filter(|t| !t.is_empty()) {
        sql.push_str(&format!(
            " AND EXISTS (SELECT 1 FROM task_tags g WHERE g.task_id = t.id AND g.tag = {})",
            arg(tag, &mut args)
        ));
    }
    if spec.min_priority != Priority::None {
        sql.push_str(&format!(" AND t.priority >= {}", spec.min_priority.as_i64()));
    }
    sql.push_str(&format!(
        " ORDER BY t.done IS NOT NULL, {date} IS NULL, coalesce(t.due, t.start), t.priority DESC, t.pos, t.id"
    ));
    let refs: Vec<&str> = args.iter().map(String::as_str).collect();
    let mut tasks = query_tasks(conn, &sql, &refs)?;
    // Matching text is done here: SQLite folds case for ASCII only.
    let words: Vec<String> = spec
        .text
        .to_lowercase()
        .split_whitespace()
        .map(str::to_string)
        .collect();
    if !words.is_empty() {
        tasks.retain(|t| {
            let hay = format!("{}\n{}", t.title, t.notes).to_lowercase();
            words.iter().all(|w| hay.contains(w))
        });
    }
    Ok(tasks)
}

fn find_list_by_name(conn: &Connection, name: &str) -> Result<Option<String>> {
    let wanted = name.to_lowercase();
    let mut stmt = conn.prepare_cached("SELECT id, name FROM lists WHERE deleted = 0 ORDER BY archived, pos, id")?;
    let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
    for row in rows {
        let (id, list_name) = row?;
        if list_name.to_lowercase() == wanted || (id == INBOX_ID && matches!(wanted.as_str(), "inbox" | "входящие"))
        {
            return Ok(Some(id));
        }
    }
    Ok(None)
}

fn create_task(w: &mut Writer, new: NewTask) -> Result<TaskItem> {
    let title = new.title.trim().to_string();
    if title.is_empty() {
        return Err(AppError::invalid("title is empty"));
    }
    valid_moment(&new.start)?;
    valid_moment(&new.due)?;
    let id = new_id();
    let mut priority = new.priority;
    let mut due = new.due.filter(|d| !d.is_empty());
    match &new.parent_id {
        Some(parent) => {
            let parent_task = get_task(w.tx, parent)?;
            w.task(&id, "parent", json!(parent))?;
            w.task(&id, "list", json!(parent_task.list_id))?;
            w.task(&id, "pos", json!(append_pos_in_parent(w.tx, parent)?))?;
        }
        None => {
            let list_id = new.list_id.unwrap_or_else(|| INBOX_ID.to_string());
            let list = get_list(w.tx, &list_id)?;
            if priority.is_none() && list.default_priority != Priority::None {
                priority = Some(list.default_priority);
            }
            if due.is_none() && new.start.is_none() && list.default_due_today {
                due = Some(w.today().format(DATE_FMT).to_string());
            }
            w.task(&id, "list", json!(list_id))?;
            w.task(&id, "pos", json!(append_pos_in_list(w.tx, &list_id)?))?;
        }
    }
    w.task(&id, "title", json!(title))?;
    if !new.notes.is_empty() {
        w.task(&id, "notes", json!(new.notes))?;
    }
    if let Some(start) = new.start.filter(|s| !s.is_empty()) {
        w.task(&id, "start", json!(start))?;
    }
    if let Some(due) = due {
        w.task(&id, "due", json!(due))?;
    }
    if let Some(priority) = priority {
        w.task(&id, "priority", json!(priority.as_i64()))?;
    }
    for tag in new.tags.iter().map(|t| clean_tag(t)).filter(|t| !t.is_empty()) {
        w.task(&id, &format!("tag:{tag}"), json!(true))?;
    }
    w.flush()?;
    get_task(w.tx, &id)
}

fn duplicate(w: &mut Writer, original: &TaskItem, parent: Option<String>) -> Result<String> {
    let copy = create_task(
        w,
        NewTask {
            title: original.title.clone(),
            list_id: Some(original.list_id.clone()),
            parent_id: parent,
            notes: original.notes.clone(),
            start: original.start.clone(),
            due: original.due.clone(),
            priority: Some(original.priority),
            tags: original.tags.clone(),
        },
    )?;
    if let Some(rule) = &original.repeat {
        w.task(&copy.id, "repeat", serde_json::to_value(rule)?)?;
    }
    if let Some(remind) = &original.remind {
        w.task(&copy.id, "remind", json!(remind))?;
    }
    let mut stmt = w
        .tx
        .prepare("SELECT name, mime, size, sha256 FROM attachments WHERE task_id = ?1 AND deleted = 0 ORDER BY id")?;
    let files: Vec<(String, String, i64, String)> = stmt
        .query_map([&original.id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
        .collect::<rusqlite::Result<_>>()?;
    drop(stmt);
    for (name, mime, size, sha256) in files {
        let id = new_id();
        w.set(KIND_ATTACHMENT, &id, "task", json!(copy.id))?;
        w.set(KIND_ATTACHMENT, &id, "name", json!(name))?;
        w.set(KIND_ATTACHMENT, &id, "mime", json!(mime))?;
        w.set(KIND_ATTACHMENT, &id, "size", json!(size))?;
        w.set(KIND_ATTACHMENT, &id, "sha256", json!(sha256))?;
    }
    let children = query_tasks(
        w.tx,
        "WHERE t.eff_parent = ?1 AND t.deleted = 0 AND t.purged = 0 ORDER BY t.pos, t.id",
        &[&original.id],
    )?;
    for child in children {
        if child.id != copy.id {
            duplicate(w, &child, Some(copy.id.clone()))?;
        }
    }
    Ok(copy.id)
}

/// Writes down the cuts that `rebuild_tree` made to break cycles.
///
/// A cut is only a way of reading the stored parents. Without this, moving one
/// task of a former cycle would bring the suppressed parent of another back to
/// life and rearrange the tree behind the user's back.
fn heal_tree(w: &mut Writer) -> Result<()> {
    let mut stmt = w.tx.prepare(
        "SELECT id FROM tasks WHERE parent_id IS NOT NULL AND eff_parent IS NULL AND parent_id != id
           AND parent_id IN (SELECT id FROM tasks)",
    )?;
    let cut: Vec<String> = stmt.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
    drop(stmt);
    for id in &cut {
        w.task(id, "parent", Value::Null)?;
    }
    if !cut.is_empty() {
        w.flush()?;
    }
    Ok(())
}

fn sibling_positions(conn: &Connection, filter: &str, arg: &str, except: &str) -> Result<Vec<(String, String)>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT id, pos FROM tasks WHERE {filter} AND id != ?2 AND eff_deleted = 0 AND log_of IS NULL ORDER BY pos, id"
    ))?;
    let rows = stmt.query_map(params![arg, except], |r| Ok((r.get(0)?, r.get(1)?)))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// Position right after `after` in an ordered sibling list, or before the first one.
fn pos_after(siblings: &[(String, String)], after: Option<&str>) -> String {
    let index = after.and_then(|a| siblings.iter().position(|(id, _)| id == a));
    let (lo, hi) = match index {
        Some(i) => (Some(siblings[i].1.as_str()), siblings.get(i + 1).map(|s| s.1.as_str())),
        None => (None, siblings.first().map(|s| s.1.as_str())),
    };
    order::between(lo, hi)
}

fn place_after(w: &mut Writer, id: &str, anchor: &TaskItem) -> Result<()> {
    let siblings = match &anchor.parent_id {
        Some(parent) => sibling_positions(w.tx, "eff_parent = ?1", parent, id)?,
        None => sibling_positions(w.tx, "eff_list = ?1 AND eff_parent IS NULL", &anchor.list_id, id)?,
    };
    let pos = pos_after(&siblings, Some(&anchor.id));
    w.task(id, "pos", json!(pos))
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Days between two calendar dates, used by the apps for "in 3 days" labels.
#[uniffi::export]
pub fn days_between(from: String, to: String) -> Option<i64> {
    let (a, _) = recur::split(&from)?;
    let (b, _) = recur::split(&to)?;
    Some((b - a).num_days())
}

/// The date `days` after `date`, keeping its time part.
#[uniffi::export]
pub fn shift_date(date: String, days: i64) -> Option<String> {
    recur::shift(&date, days)
}
