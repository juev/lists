//! Web interface for Lists.
//!
//! The server is one more device: it keeps its own copy of the data, syncs it
//! like the apps do, and shows it to a browser. A browser cannot talk to a
//! WebDAV or CalDAV server on another origin, so this is what makes Lists
//! reachable from a phone without a native app.

mod notify;
mod oidc;
mod tokens;
mod webpush;

use std::collections::{HashMap, VecDeque};
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::SocketAddr;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub use oidc::OidcConfig;

use lists_core::{
    markdown_layout, AppError, Attachment, AttachmentLimits, FilterSpec, KeepDone, MarkdownAlign, MarkdownKind,
    NewTask, Priority, Repeat, Scope, SortMode, Store, SyncConfig, TaskItem, TaskList, DEFAULT_MAX_FILE,
    DEFAULT_MAX_TASK,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tiny_http::{Header, Method, Request, Response, ResponseBox, Server};

const INDEX: &str = include_str!("index.html");
const MANIFEST: &str = include_str!("manifest.json");
/// R146, R149: shows the notifications and keeps the page for when the server cannot be reached.
const SERVICE_WORKER: &str = include_str!("sw.js");
const ICON: &str = include_str!("icon.svg");
// Bitmaps for what cannot use the SVG: the iOS home screen, the install
// prompt, and browsers that only take a PNG for the tab.
const ICON_32: &[u8] = include_bytes!("icon-32.png");
const ICON_180: &[u8] = include_bytes!("icon-180.png");
const ICON_192: &[u8] = include_bytes!("icon-192.png");
const ICON_512: &[u8] = include_bytes!("icon-512.png");
const COOKIE: &str = "lists_session";
/// Request bodies above this are refused; it bounds a JSON import.
const MAX_BODY: usize = 64 * 1024 * 1024;
const SESSION_TTL: Duration = Duration::from_secs(30 * 24 * 3600);
/// R135: no zone is further from UTC than fourteen hours.
const MAX_ZONE_MINUTES: i32 = 14 * 60;
/// R134: a login carries a password and nothing more.
const LOGIN_MAX_BODY: usize = 4 * 1024;
/// R134: this many failed logins within `LOGIN_WINDOW` and the client is refused until the window frees up.
const LOGIN_LIMIT: usize = 5;
const LOGIN_WINDOW: Duration = Duration::from_secs(60);
/// R134: how many clients' failed logins are remembered at most.
const LOGIN_CLIENTS: usize = 10_000;

pub struct Config {
    pub data_dir: String,
    pub listen: String,
    /// Password for the web interface. `None` disables the login and is only
    /// accepted by `main` on a loopback address.
    pub password: Option<String>,
    /// Sign-in through an OpenID Connect provider, alone or next to the password.
    pub oidc: Option<OidcConfig>,
    pub sync: SyncConfig,
    pub sync_password: Option<String>,
    /// S58: the passphrase of an encrypted storage.
    pub sync_passphrase: Option<String>,
    /// ntfy server through which other devices ask this one to sync.
    pub push_server: Option<String>,
    /// Access token for that server, when it requires sign-in (S27).
    pub push_token: Option<String>,
    /// R134: the client is the last address of `X-Forwarded-For`, which a reverse proxy appends.
    pub trust_proxy: bool,
    /// R134: the session cookie is `Secure`, for a server the browser reaches over HTTPS.
    pub secure_cookie: bool,
    /// R140: the largest one attachment may be, in bytes; `None` keeps the default. Zero means no
    /// limit. Read once, when the server opens the store.
    pub max_file: Option<u64>,
    /// R140: the most all live attachments of one task may weigh; `None` keeps the default.
    pub max_task: Option<u64>,
    /// R148: the contact push services see in the VAPID token, `mailto:` or `https:`.
    pub vapid_subject: Option<String>,
}

/// R148: what the token says when nothing is configured; Apple refuses a token without a contact.
const VAPID_SUBJECT: &str = "https://github.com/juev/lists";

struct App {
    store: Arc<Store>,
    password: Option<String>,
    oidc: Option<oidc::Oidc>,
    /// Session token → when it stops being valid.
    sessions: Mutex<HashMap<String, Instant>>,
    trust_proxy: bool,
    secure_cookie: bool,
    /// Client → when its failed logins within `LOGIN_WINDOW` were, oldest first.
    failures: Mutex<HashMap<String, VecDeque<Instant>>>,
    /// Set by a change, cleared by the sync thread.
    dirty: AtomicBool,
    notifier: notify::Notifier,
    tokens: tokens::Tokens,
}

pub struct Running {
    pub addr: SocketAddr,
}

type Reply = ResponseBox;

fn header(name: &str, value: &str) -> Header {
    Header::from_bytes(name.as_bytes(), value.as_bytes()).expect("static header")
}

fn reply(code: u16, content_type: &str, body: impl Into<Vec<u8>>) -> Reply {
    Response::from_data(body.into())
        .with_status_code(code)
        .with_header(header("Content-Type", content_type))
        .with_header(header("Cache-Control", "no-store"))
        .with_header(header("X-Content-Type-Options", "nosniff"))
        .with_header(header("Referrer-Policy", "no-referrer"))
        .boxed()
}

fn json_reply(code: u16, value: Value) -> Reply {
    reply(code, "application/json; charset=utf-8", value.to_string())
}

/// A minimal page for the sign-in round trip: on success it goes to the app,
/// otherwise it says why not. The message is escaped; nothing else is dynamic.
fn page(code: u16, message: &str) -> Reply {
    let safe = message.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;");
    let body = if code == 200 {
        "<!doctype html><meta charset=utf-8><title>Lists</title><script>location.replace('/')</script>".to_string()
    } else {
        format!("<!doctype html><meta charset=utf-8><title>Lists</title><body style=\"font:16px sans-serif;margin:15vh auto;max-width:420px\"><h1>Lists</h1><p>{safe}</p><p><a href=\"/\">Back</a></p>")
    };
    reply(code, "text/html; charset=utf-8", body).with_header(header(
        "Content-Security-Policy",
        "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'",
    ))
}

fn fail(code: u16, message: impl Into<String>) -> Reply {
    json_reply(code, json!({ "error": message.into() }))
}

/// Compares secrets through their hashes, so timing says nothing about the content.
fn same_secret(a: &str, b: &str) -> bool {
    Sha256::digest(a.as_bytes()) == Sha256::digest(b.as_bytes())
}

fn priority_from(n: i64) -> Priority {
    match n {
        1 => Priority::Low,
        2 => Priority::Medium,
        3 => Priority::High,
        _ => Priority::None,
    }
}

fn priority_to(p: Priority) -> i64 {
    match p {
        Priority::None => 0,
        Priority::Low => 1,
        Priority::Medium => 2,
        Priority::High => 3,
    }
}

fn sort_name(sort: SortMode) -> &'static str {
    match sort {
        SortMode::Manual => "manual",
        SortMode::Due => "due",
        SortMode::Priority => "priority",
        SortMode::Title => "title",
    }
}

fn task_json(t: &TaskItem) -> Value {
    json!({
        "id": t.id, "list": t.list_id, "parent": t.parent_id, "parentTitle": t.parent_title,
        "title": t.title, "notes": t.notes, "start": t.start, "due": t.due,
        "effectiveStart": t.effective_start, "effectiveDue": t.effective_due,
        "priority": priority_to(t.priority), "tags": t.tags,
        "repeat": t.repeat.as_ref().and_then(|r| serde_json::to_value(r).ok()),
        "remind": t.remind, "done": t.done, "wont": t.wont, "deleted": t.deleted, "log": t.is_log,
        "undoable": t.undoable, "project": t.is_project,
        "subtasks": t.subtasks_total, "subtasksDone": t.subtasks_done, "attachments": t.attachments,
    })
}

/// A subtask under a task found by a search (R22): a mark and a title, which is all it has (R10).
fn found_json(t: &TaskItem) -> Value {
    json!({ "id": t.id, "title": t.title, "done": t.done, "wont": t.wont })
}

/// The ranges of a note to style, hide and replace (R53), in UTF-16 units, which
/// is how the page indexes the text. The page builds text nodes from them and
/// never markup.
fn markdown_json(notes: &str) -> (Value, Value) {
    let layout = markdown_layout(notes.to_string());
    // R60: the page builds a table element from the cells; the line of dashes is not among the rows.
    let tables = layout.tables.iter().map(|table| {
        let columns = table.columns.iter().map(|align| match align {
            MarkdownAlign::None => "",
            MarkdownAlign::Left => "left",
            MarkdownAlign::Center => "center",
            MarkdownAlign::Right => "right",
        });
        let rows = table.rows.iter().map(|row| {
            json!({
                "header": row.header,
                "cells": row.cells.iter().map(|c| json!([c.start, c.end])).collect::<Vec<_>>(),
            })
        });
        json!({
            "start": table.start, "end": table.end,
            "columns": columns.collect::<Vec<_>>(), "rows": rows.collect::<Vec<_>>(),
        })
    });
    let tables = Value::Array(tables.collect());
    let spans = layout.spans.into_iter().map(|span| {
        let (kind, detail) = match span.kind {
            MarkdownKind::Heading { level } => ("heading", json!(level)),
            MarkdownKind::Strong => ("strong", Value::Null),
            MarkdownKind::Emphasis => ("emphasis", Value::Null),
            MarkdownKind::Strikethrough => ("strike", Value::Null),
            MarkdownKind::Code => ("code", Value::Null),
            MarkdownKind::CodeBlock => ("codeBlock", Value::Null),
            MarkdownKind::Quote => ("quote", Value::Null),
            MarkdownKind::Link { url } => ("link", json!(url)),
            MarkdownKind::ListMarker { ordered } => ("marker", json!(ordered)),
            MarkdownKind::QuoteMarker => ("quoteMarker", Value::Null),
            MarkdownKind::Checkbox { checked } => ("checkbox", json!(checked)),
            MarkdownKind::Rule => ("rule", Value::Null),
            MarkdownKind::TableRow => ("tableRow", Value::Null),
            MarkdownKind::Markup => ("markup", Value::Null),
        };
        json!([span.start, span.end, kind, detail])
    });
    (Value::Array(spans.collect()), tables)
}

fn list_json(l: &TaskList) -> Value {
    json!({
        "id": l.id, "name": l.name, "color": l.color, "icon": l.icon, "sort": sort_name(l.sort),
        "showDone": l.show_done, "defaultPriority": priority_to(l.default_priority),
        "defaultDueToday": l.default_due_today, "archived": l.archived, "open": l.open_count,
    })
}

/// What the page may show in place (R56): `image` or `pdf`, decided from a fixed list of types.
/// SVG and HTML are not on it, so they can never run on this origin; everything else downloads.
fn preview_kind(mime: &str) -> Option<&'static str> {
    match mime {
        "image/png" | "image/jpeg" | "image/gif" | "image/webp" => Some("image"),
        "application/pdf" => Some("pdf"),
        _ => None,
    }
}

fn attachment_json(a: &Attachment) -> Value {
    json!({
        "id": a.id, "name": a.name, "mime": a.mime, "size": a.size, "present": a.local_path.is_some(),
        "preview": preview_kind(&a.mime),
    })
}

/// A file shown in place loads nothing and runs nothing, whatever it turns out to hold.
const PREVIEW_POLICY: &str = "default-src 'none'; sandbox";

/// `inbox`, `today`, `list:<id>`, `tag:<name>`, `search:<text>` …
fn scope_from(text: &str) -> Option<Scope> {
    Some(match text.split_once(':') {
        Some(("list", id)) => Scope::List { id: id.to_string() },
        Some(("tag", name)) => Scope::Tag { name: name.to_string() },
        Some(("search", q)) => Scope::Search { text: q.to_string() },
        Some(("project", id)) => Scope::Project { id: id.to_string() },
        Some(("filter", id)) => Scope::Filter { id: id.to_string() },
        Some(_) => return None,
        None => match text {
            "inbox" => Scope::Inbox,
            "today" => Scope::Today,
            "upcoming" => Scope::Upcoming,
            "all" => Scope::All,
            "completed" => Scope::Completed,
            "wontdo" => Scope::WontDo,
            "trash" => Scope::Trash,
            _ => return None,
        },
    })
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match (
            bytes[i],
            s.get(i + 1..i + 3).and_then(|h| u8::from_str_radix(h, 16).ok()),
        ) {
            (b'%', Some(byte)) => {
                out.push(byte);
                i += 3;
            }
            (b'+', _) => {
                out.push(b' ');
                i += 1;
            }
            (b, _) => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn query(url: &str, name: &str) -> Option<String> {
    let (_, q) = url.split_once('?')?;
    q.split('&')
        .filter_map(|p| p.split_once('='))
        .find(|(k, _)| *k == name)
        .map(|(_, v)| percent_decode(v))
}

fn text_arg(args: &Value, name: &str) -> Result<String, AppError> {
    args.get(name)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| AppError::Invalid {
            msg: format!("missing {name}"),
        })
}

/// Absent, null and "" all mean "no value".
fn optional(args: &Value, name: &str) -> Option<String> {
    args.get(name)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// S34: attachment content moves on a thread of its own, so that the next run
/// for the fields does not wait for it. The core lets one pass go at a time.
fn move_attachments(store: &Arc<Store>) {
    let store = store.clone();
    std::thread::spawn(move || {
        let _ = store.sync_attachments();
    });
}

impl App {
    fn overview(&self) -> Result<Value, AppError> {
        let s = &self.store;
        let counts = s.counts()?;
        let status = s.sync_status()?;
        Ok(json!({
            "lists": s.lists()?.iter().map(list_json).collect::<Vec<_>>(),
            "tags": s.tags()?.iter().map(|t| json!({ "name": t.name, "open": t.open_count })).collect::<Vec<_>>(),
            "projects": s.projects()?.iter().map(task_json).collect::<Vec<_>>(),
            "filters": s.filters()?.iter().map(|f| json!({ "id": f.id, "name": f.name, "open": f.open_count, "spec": serde_json::to_value(&f.spec).unwrap_or(Value::Null) })).collect::<Vec<_>>(),
            "counts": { "inbox": counts.inbox, "today": counts.today, "overdue": counts.overdue, "upcoming": counts.upcoming, "trash": counts.trash },
            "sync": { "configured": status.configured, "pending": status.pending, "attachmentsWaiting": status.attachments_waiting, "lastOk": status.last_ok, "lastError": status.last_error },
            // Seconds, or "day" for the end of the day (R68).
            "keepDone": match s.keep_done()? {
                KeepDone::Seconds { seconds } => json!(seconds),
                KeepDone::EndOfDay => json!("day"),
            },
            "keptFor": s.seconds_until_kept_leaves()?,
        }))
    }

    /// R118: one action on several tasks, in the order they were given. A task the action does not
    /// apply to is passed over. The answer holds how many tasks were changed; one undo takes them
    /// all back (R131).
    fn batch(&self, a: &Value) -> Result<Value, AppError> {
        self.store.begin_group();
        let out = self.batch_steps(a);
        self.store.end_group();
        out
    }

    fn batch_steps(&self, a: &Value) -> Result<Value, AppError> {
        let s = &self.store;
        let action = text_arg(a, "action")?;
        let ids: Vec<String> = a
            .get("ids")
            .and_then(Value::as_array)
            .map(|ids| ids.iter().filter_map(|id| id.as_str().map(str::to_string)).collect())
            .unwrap_or_default();
        let value = optional(a, "value");
        let priority = priority_from(a.get("value").and_then(Value::as_i64).unwrap_or(0));
        let tag = value
            .clone()
            .unwrap_or_default()
            .trim()
            .trim_start_matches('#')
            .to_lowercase();
        let need = |what: &str| {
            value.clone().ok_or(AppError::Invalid {
                msg: format!("{what} is missing"),
            })
        };
        // A subtask stays with its task (R10); the tasks of a project are full tasks (R30).
        let subtask = |task: &TaskItem| {
            task.parent_id
                .as_ref()
                .is_some_and(|parent| s.task(parent.clone()).is_ok_and(|p| !p.is_project))
        };
        let mut changed = 0;
        for id in ids {
            // Read anew: a task that is gone by now is passed over.
            let Ok(task) = s.task(id.clone()) else { continue };
            // A task in the trash is only restored, and a record of a completed occurrence only deleted.
            if task.deleted {
                if action != "restore" {
                    continue;
                }
                s.restore_task(id.clone())?;
            } else if task.is_log {
                if action != "delete" {
                    continue;
                }
                s.delete_task(id.clone())?;
            } else {
                match action.as_str() {
                    "complete" | "wontDo" => {
                        if task.done.is_some() {
                            continue;
                        }
                        if action == "complete" {
                            s.complete_task(id.clone())?;
                        } else {
                            s.wont_do_task(id.clone())?;
                        }
                    }
                    "delete" => {
                        s.delete_task(id.clone())?;
                    }
                    "due" => {
                        let due = need("the date")?;
                        if task.due.as_deref() == Some(due.as_str()) {
                            continue;
                        }
                        s.set_due(id.clone(), Some(due))?;
                    }
                    "start" => {
                        let start = need("the date")?;
                        if task.start.as_deref() == Some(start.as_str()) {
                            continue;
                        }
                        s.set_start(id.clone(), Some(start))?;
                    }
                    "priority" => {
                        if task.priority == priority {
                            continue;
                        }
                        s.set_priority(id.clone(), priority)?;
                    }
                    "move" => {
                        let list = need("the list")?;
                        if subtask(&task) || (task.parent_id.is_none() && task.list_id == list) {
                            continue;
                        }
                        s.move_to_list(id.clone(), list)?;
                    }
                    // R129: the skips of a drop onto a project (R123).
                    "project" => {
                        let project = need("the project")?;
                        if subtask(&task)
                            || task.is_project
                            || task.subtasks_total > 0
                            || task.id == project
                            || task.parent_id.as_deref() == Some(project.as_str())
                        {
                            continue;
                        }
                        s.move_to_project(id.clone(), project)?;
                    }
                    "tag" => {
                        if tag.is_empty() || task.tags.contains(&tag) {
                            continue;
                        }
                        s.add_tag(id.clone(), tag.clone())?;
                    }
                    _ => continue,
                }
            }
            changed += 1;
        }
        Ok(json!({ "changed": changed }))
    }

    fn call(&self, op: &str, a: &Value) -> Result<Value, AppError> {
        let s = &self.store;
        let id = || text_arg(a, "id");
        let done = json!({ "ok": true });
        let out =
            match op {
                "quickAdd" => {
                    let scope = optional(a, "scope").unwrap_or_default();
                    let list = scope.strip_prefix("list:").map(str::to_string);
                    if let Some(project) = scope.strip_prefix("project:") {
                        self.dirty.store(true, Ordering::Relaxed);
                        return Ok(task_json(
                            // R130: a new task goes first; the page has no selected task to go under.
                            &s.quick_add_under(text_arg(a, "text")?, project.to_string(), true, None)?,
                        ));
                    }
                    // The view gives a task its list and nothing else (R75).
                    task_json(&s.quick_add(text_arg(a, "text")?, list, true, None)?)
                }
                "addSubtask" => task_json(&s.create_task(NewTask {
                    title: text_arg(a, "title")?,
                    parent_id: Some(text_arg(a, "parent")?),
                    ..NewTask::default()
                })?),
                "setTitle" => s.set_title(id()?, text_arg(a, "value")?).map(|_| done)?,
                "setNotes" => s
                    .set_notes(
                        id()?,
                        a.get("value").and_then(Value::as_str).unwrap_or_default().to_string(),
                    )
                    .map(|_| done)?,
                "setStart" => s.set_start(id()?, optional(a, "value")).map(|_| done)?,
                "setDue" => s.set_due(id()?, optional(a, "value")).map(|_| done)?,
                "setRemind" => s.set_remind(id()?, optional(a, "value")).map(|_| done)?,
                "setPriority" => s
                    .set_priority(
                        id()?,
                        priority_from(a.get("value").and_then(Value::as_i64).unwrap_or(0)),
                    )
                    .map(|_| done)?,
                "setRepeat" => {
                    let rule = match a.get("value") {
                        None | Some(Value::Null) => None,
                        Some(v) => Some(
                            serde_json::from_value::<Repeat>(v.clone())
                                .map_err(|e| AppError::Invalid { msg: e.to_string() })?,
                        ),
                    };
                    s.set_repeat(id()?, rule).map(|_| done)?
                }
                "addTag" => s.add_tag(id()?, text_arg(a, "value")?).map(|_| done)?,
                "removeTag" => s.remove_tag(id()?, text_arg(a, "value")?).map(|_| done)?,
                "complete" => task_json(&s.complete_task(id()?)?),
                "wontDo" => task_json(&s.wont_do_task(id()?)?),
                "reopen" => s.reopen_task(id()?).map(|_| done)?,
                "undoClose" => s.undo_close_task(id()?).map(|_| done)?,
                "delete" => s.delete_task(id()?).map(|_| done)?,
                "restore" => s.restore_task(id()?).map(|_| done)?,
                "emptyTrash" => json!({ "removed": s.empty_trash()? }),
                // An empty day is refused by the core rather than read as "everything".
                "clearCompleted" => {
                    let before = a.get("before").and_then(Value::as_str).map(str::to_string);
                    json!({ "removed": s.clear_completed(before)? })
                }
                "moveToList" => s.move_to_list(id()?, text_arg(a, "list")?).map(|_| done)?,
                "moveToProject" => s.move_to_project(id()?, text_arg(a, "project")?).map(|_| done)?,
                "batch" => self.batch(a)?,
                // R131: the last action of this session, however many tasks it changed.
                "undo" => json!({ "changed": s.undo()? }),
                "duplicate" => task_json(&s.duplicate_task(id()?)?),
                "createList" => list_json(&s.create_list(text_arg(a, "name")?)?),
                "renameList" => s.rename_list(id()?, text_arg(a, "value")?).map(|_| done)?,
                "setListColor" => s
                    .set_list_color(
                        id()?,
                        a.get("value").and_then(Value::as_str).unwrap_or_default().to_string(),
                    )
                    .map(|_| done)?,
                "setListSort" => {
                    let sort = match text_arg(a, "value")?.as_str() {
                        "due" => SortMode::Due,
                        "priority" => SortMode::Priority,
                        "title" => SortMode::Title,
                        _ => SortMode::Manual,
                    };
                    s.set_list_sort(id()?, sort).map(|_| done)?
                }
                "setListShowDone" => s
                    .set_list_show_done(id()?, a.get("value").and_then(Value::as_bool).unwrap_or(false))
                    .map(|_| done)?,
                "setKeepDone" => {
                    let keep = match a.get("value") {
                        Some(Value::String(day)) if day == "day" => KeepDone::EndOfDay,
                        Some(value) => KeepDone::Seconds {
                            seconds: value
                                .as_u64()
                                .map(|seconds| u32::try_from(seconds).unwrap_or(u32::MAX))
                                .ok_or_else(|| AppError::invalid("value"))?,
                        },
                        None => return Err(AppError::invalid("value")),
                    };
                    s.set_keep_done(keep).map(|_| done)?
                }
                "deleteList" => s.delete_list(id()?).map(|_| done)?,
                "setProject" => s
                    .set_project(id()?, a.get("value").and_then(Value::as_bool).unwrap_or(false))
                    .map(|_| done)?,
                // R127: the list of the view, of the open project, or the default one (R40).
                "createProject" => {
                    let scope = optional(a, "scope").unwrap_or_default();
                    let list = match scope.split_once(':') {
                        Some(("list", list)) => Some(list.to_string()),
                        Some(("project", project)) => Some(s.task(project.to_string())?.list_id),
                        _ if scope == "inbox" => Some("inbox".to_string()),
                        _ => None,
                    };
                    task_json(&s.create_project(text_arg(a, "title")?, list)?)
                }
                "createFilter" | "updateFilter" => {
                    let spec: FilterSpec = serde_json::from_value(a.get("spec").cloned().unwrap_or(Value::Null))
                        .map_err(|e| AppError::Invalid {
                            msg: format!("bad filter: {e}"),
                        })?;
                    if op == "createFilter" {
                        json!({ "id": s.create_filter(text_arg(a, "name")?, spec)?.id })
                    } else {
                        s.update_filter(id()?, text_arg(a, "name")?, spec).map(|_| done)?
                    }
                }
                "deleteFilter" => s.delete_filter(id()?).map(|_| done)?,
                "removeAttachment" => s.remove_attachment(id()?).map(|_| done)?,
                "sync" => {
                    let report = s.sync_now()?;
                    move_attachments(&self.store);
                    json!({ "pulled": report.pulled, "pushed": report.pushed })
                }
                other => {
                    return Err(AppError::Invalid {
                        msg: format!("unknown operation {other}"),
                    })
                }
            };
        if op != "sync" {
            self.dirty.store(true, Ordering::Relaxed);
        }
        Ok(out)
    }

    fn session(&self, request: &Request) -> Option<String> {
        let cookies = request
            .headers()
            .iter()
            .find(|h| h.field.equiv("Cookie"))?
            .value
            .as_str()
            .to_string();
        let token = cookies
            .split(';')
            .filter_map(|c| c.trim().split_once('='))
            .find(|(k, _)| *k == COOKIE)?
            .1
            .to_string();
        let mut sessions = self.sessions.lock().unwrap_or_else(|p| p.into_inner());
        sessions.retain(|_, until| *until > Instant::now());
        sessions.contains_key(&token).then_some(token)
    }

    /// Starts a session and returns the cookie that carries it.
    fn open_session(&self) -> Header {
        let token = format!("{}{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple());
        self.sessions
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .insert(token.clone(), Instant::now() + SESSION_TTL);
        let secure = if self.secure_cookie { "; Secure" } else { "" };
        header(
            "Set-Cookie",
            &format!(
                "{COOKIE}={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={}{secure}",
                SESSION_TTL.as_secs()
            ),
        )
    }

    /// Who is asking, for counting failed logins (R134).
    fn client(&self, request: &Request) -> String {
        let forwarded = self
            .trust_proxy
            .then(|| request.headers().iter().find(|h| h.field.equiv("X-Forwarded-For")))
            .flatten()
            .and_then(|h| h.value.as_str().rsplit(',').next().map(|a| a.trim().to_string()))
            .filter(|a| !a.is_empty());
        forwarded
            .or_else(|| request.remote_addr().map(|a| a.ip().to_string()))
            .unwrap_or_default()
    }

    /// Counts a login attempt as failed until it succeeds, so that attempts made at the same
    /// time cannot check more passwords than the limit allows. Returns how many the client
    /// has within the window, or how long it is still refused.
    /// R152: how long the client is still refused, without counting this as an attempt.
    fn refused(&self, client: &str) -> Option<Duration> {
        let mut failures = self.failures.lock().unwrap_or_else(|p| p.into_inner());
        let times = failures.get_mut(client)?;
        while times.front().is_some_and(|t| t.elapsed() >= LOGIN_WINDOW) {
            times.pop_front();
        }
        (times.len() >= LOGIN_LIMIT).then(|| LOGIN_WINDOW.saturating_sub(times[0].elapsed()))
    }

    /// R151, R152: the token a request carries, or the answer that turns it away. Unlike a
    /// password, a token is counted as an attempt only once it has failed: it is 256 random bits,
    /// and requests a script makes at once must not refuse each other.
    fn token_caller(
        &self,
        request: &Request,
        method: &Method,
        path: &str,
        secret: &str,
    ) -> Result<tokens::Caller, Reply> {
        let client = self.client(request);
        let too_many = |wait: Duration| {
            fail(429, "too many requests").with_header(header("Retry-After", &(wait.as_secs() + 1).to_string()))
        };
        if let Some(wait) = self.refused(&client) {
            return Err(too_many(wait));
        }
        let Some(caller) = self.tokens.check(secret) else {
            let count = self.attempt(&client).unwrap_or(LOGIN_LIMIT);
            eprintln!(
                "lists-web: a request with an unknown API token from {client} ({count} failures in the last minute)"
            );
            return Err(fail(401, "unknown or revoked token"));
        };
        if let Err(wait) = self.tokens.allow(&caller.id) {
            eprintln!(
                "lists-web: the API token \"{}\" made more than {} requests in a minute",
                caller.name,
                tokens::LIMIT
            );
            return Err(too_many(wait));
        }
        if path == "/api/logout" || path.starts_with("/api/tokens") || path.starts_with("/api/notifications") {
            return Err(fail(403, "this needs a session of the web interface"));
        }
        if caller.scope == tokens::Scope::Read && !matches!(method, Method::Get | Method::Head) {
            return Err(fail(403, "this token may only read"));
        }
        Ok(caller)
    }

    fn attempt(&self, client: &str) -> Result<usize, Duration> {
        let mut failures = self.failures.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(times) = failures.get_mut(client) {
            while times.front().is_some_and(|t| t.elapsed() >= LOGIN_WINDOW) {
                times.pop_front();
            }
            if times.len() >= LOGIN_LIMIT {
                return Err(LOGIN_WINDOW.saturating_sub(times[0].elapsed()));
            }
        } else if failures.len() >= LOGIN_CLIENTS {
            failures.retain(|_, times| times.back().is_some_and(|t| t.elapsed() < LOGIN_WINDOW));
            if failures.len() >= LOGIN_CLIENTS {
                let oldest = failures
                    .iter()
                    .min_by_key(|(_, times)| times.back().copied())
                    .map(|(c, _)| c.clone());
                if let Some(oldest) = oldest {
                    failures.remove(&oldest);
                }
            }
        }
        let times = failures.entry(client.to_string()).or_default();
        times.push_back(Instant::now());
        Ok(times.len())
    }

    fn authorized(&self, request: &Request) -> bool {
        (self.password.is_none() && self.oidc.is_none()) || self.session(request).is_some()
    }

    fn body(request: &mut Request) -> Result<Vec<u8>, Reply> {
        Self::body_within(request, MAX_BODY)
    }

    /// A small JSON body, as the notification calls send.
    fn json_body(request: &mut Request) -> Result<Value, Reply> {
        let body = Self::body_within(request, 16 * 1024)?;
        serde_json::from_slice(&body).map_err(|e| fail(400, e.to_string()))
    }

    fn body_within(request: &mut Request, limit: usize) -> Result<Vec<u8>, Reply> {
        if request.body_length().is_some_and(|n| n > limit) {
            return Err(fail(413, "too large"));
        }
        let mut data = Vec::new();
        request
            .as_reader()
            .take(limit as u64 + 1)
            .read_to_end(&mut data)
            .map_err(|e| fail(400, e.to_string()))?;
        if data.len() > limit {
            return Err(fail(413, "too large"));
        }
        Ok(data)
    }

    /// R140: an upload goes to the disk in pieces, so the server does not hold the file in memory.
    /// Returns the number of bytes written; zero as the limit means no limit.
    fn save_body(request: &mut Request, file: &Path, limit: u64) -> Result<u64, Reply> {
        if limit != 0 && request.body_length().is_some_and(|n| n as u64 > limit) {
            return Err(fail(413, "too large: this server takes smaller files"));
        }
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut out = options.open(file).map_err(|e| fail(500, e.to_string()))?;
        let reader = request.as_reader();
        let mut buffer = [0u8; 64 * 1024];
        let mut size = 0u64;
        loop {
            let read = reader.read(&mut buffer).map_err(|e| fail(400, e.to_string()))?;
            if read == 0 {
                break;
            }
            size += read as u64;
            if limit != 0 && size > limit {
                return Err(fail(413, "too large: this server takes smaller files"));
            }
            out.write_all(&buffer[..read]).map_err(|e| fail(500, e.to_string()))?;
        }
        out.flush().map_err(|e| fail(500, e.to_string()))?;
        Ok(size)
    }

    fn handle(&self, request: &mut Request) -> Reply {
        let url = request.url().to_string();
        let path = url.split('?').next().unwrap_or_default().to_string();
        let method = request.method().clone();
        match (&method, path.as_str()) {
            (Method::Get, "/") => {
                return reply(200, "text/html; charset=utf-8", INDEX).with_header(header(
                    "Content-Security-Policy",
                    "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; frame-ancestors 'none'",
                ))
            }
            // R144: for the health check of a container or a proxy; it says nothing but that the
            // server answers, so it needs no session.
            (Method::Get, "/healthz") => return reply(200, "text/plain; charset=utf-8", "ok"),
            (Method::Get, "/manifest.json") => return reply(200, "application/manifest+json", MANIFEST),
            // A new version of the page reaches the browser through a new worker, so it is never cached.
            (Method::Get, "/sw.js") => {
                return reply(200, "text/javascript; charset=utf-8", SERVICE_WORKER)
                    .with_header(header("Cache-Control", "no-cache"))
            }
            (Method::Get, "/icon.svg") => return reply(200, "image/svg+xml", ICON),
            (Method::Get, "/icon-32.png") | (Method::Get, "/favicon.ico") => return reply(200, "image/png", ICON_32),
            (Method::Get, "/icon-180.png") | (Method::Get, "/apple-touch-icon.png") => {
                return reply(200, "image/png", ICON_180)
            }
            (Method::Get, "/icon-192.png") => return reply(200, "image/png", ICON_192),
            (Method::Get, "/icon-512.png") => return reply(200, "image/png", ICON_512),
            (Method::Post, "/api/login") => {
                if request.body_length().is_some_and(|n| n > LOGIN_MAX_BODY) {
                    return fail(413, "too large");
                }
                let client = self.client(request);
                let count = match self.attempt(&client) {
                    Ok(count) => count,
                    Err(wait) => {
                        return fail(429, "too many failed logins")
                            .with_header(header("Retry-After", &(wait.as_secs() + 1).to_string()))
                    }
                };
                let body = match Self::body_within(request, LOGIN_MAX_BODY) {
                    Ok(b) => b,
                    Err(r) => return r,
                };
                let given = serde_json::from_slice::<Value>(&body).ok().and_then(|v| v.get("password").and_then(Value::as_str).map(str::to_string));
                let correct = match (&self.password, given) {
                    (Some(expected), Some(given)) => same_secret(&given, expected),
                    // No password is set: open only when there is no other way in to guard.
                    (None, _) => self.oidc.is_none(),
                    _ => false,
                };
                if !correct {
                    // Guessing is slowed down by the limit, not by holding the thread.
                    eprintln!("lists-web: failed login from {client} ({count} in the last minute)");
                    if count == LOGIN_LIMIT {
                        eprintln!("lists-web: logins from {client} are refused for a minute: too many failed attempts");
                    }
                    return fail(401, "wrong password");
                }
                self.failures.lock().unwrap_or_else(|p| p.into_inner()).remove(&client);
                return json_reply(200, json!({ "ok": true })).with_header(self.open_session());
            }
            (Method::Get, "/auth/methods") => {
                return json_reply(200, json!({ "password": self.password.is_some(), "oidc": self.oidc.is_some() }));
            }
            (Method::Get, "/auth/login") => {
                return match self.oidc.as_ref().map(|o| o.begin()) {
                    Some(Ok(location)) => reply(302, "text/plain", "").with_header(header("Location", &location)),
                    Some(Err(e)) => page(502, &e),
                    None => fail(404, "not found"),
                };
            }
            (Method::Get, "/auth/callback") => {
                let Some(oidc) = &self.oidc else {
                    return fail(404, "not found");
                };
                let (state, code) = (query(&url, "state").unwrap_or_default(), query(&url, "code").unwrap_or_default());
                return match oidc.finish(&state, &code) {
                    // A page, not a redirect: the cookie is SameSite=Strict and this
                    // request arrived from the provider's site.
                    Ok(_) => page(200, "").with_header(self.open_session()),
                    Err(e) => page(403, &e),
                };
            }
            _ => {}
        }
        if !path.starts_with("/api/") {
            return fail(404, "not found");
        }
        // R151: a script comes with a token instead of a cookie.
        let bearer = request
            .headers()
            .iter()
            .find(|h| h.field.equiv("Authorization"))
            .and_then(|h| h.value.as_str().strip_prefix("Bearer ").map(|t| t.trim().to_string()));
        let caller = match bearer {
            Some(secret) => match self.token_caller(request, &method, &path, &secret) {
                Ok(caller) => Some(caller),
                Err(reply) => return reply,
            },
            None => None,
        };
        if caller.is_none() && !self.authorized(request) {
            return fail(401, "login required");
        }
        // A cross-site form cannot set this header; together with SameSite it rules out CSRF.
        // A token is not sent by the browser on its own, so it needs no such guard.
        if caller.is_none() && method == Method::Post && !request.headers().iter().any(|h| h.field.equiv("X-Lists")) {
            return fail(400, "missing X-Lists header");
        }
        // R131: each session and each token has a history of its own.
        let actor = match &caller {
            Some(caller) => format!("token:{}", caller.id),
            None => self.session(request).unwrap_or_default(),
        };
        // R135: today and the time of day are the browser's. A request that does not give its zone
        // is answered in the server's, as before.
        let zone = request
            .headers()
            .iter()
            .find(|h| h.field.equiv("X-Lists-Zone"))
            .and_then(|h| h.value.as_str().trim().parse::<i32>().ok())
            .filter(|minutes| minutes.abs() <= MAX_ZONE_MINUTES);
        let mut run = || -> Result<Reply, AppError> {
            Ok(match (&method, path.as_str()) {
                (Method::Get, "/api/overview") => json_reply(200, self.overview()?),
                (Method::Get, "/api/tasks") => {
                    let scope = query(&url, "scope")
                        .and_then(|s| scope_from(&s))
                        .ok_or_else(|| AppError::Invalid {
                            msg: "bad scope".into(),
                        })?;
                    // R22: a task found by a search carries its subtasks whose title holds the text;
                    // a subtask is never a row of the results.
                    let search = match &scope {
                        Scope::Search { text } => Some(text.clone()),
                        _ => None,
                    };
                    let mut rows = Vec::new();
                    for task in self.store.tasks(scope)? {
                        let mut row = task_json(&task);
                        if let Some(text) = &search {
                            let found = self.store.found_subtasks(task.id.clone(), text.clone())?;
                            row["found"] = found.iter().map(found_json).collect();
                        }
                        rows.push(row);
                    }
                    json_reply(200, Value::Array(rows))
                }
                (Method::Get, "/api/task") => {
                    let id = query(&url, "id").unwrap_or_default();
                    let task = self.store.task(id.clone())?;
                    let (markdown, tables) = markdown_json(&task.notes);
                    json_reply(
                        200,
                        json!({
                            "markdown": markdown,
                            "tables": tables,
                            "task": task_json(&task),
                            "subtasks": self.store.subtasks(id.clone())?.iter().map(task_json).collect::<Vec<_>>(),
                            "attachments": self.store.attachments(id)?.iter().map(attachment_json).collect::<Vec<_>>(),
                        }),
                    )
                }
                (Method::Get, "/api/file") | (Method::Head, "/api/file") => {
                    let (task, id) = (
                        query(&url, "task").unwrap_or_default(),
                        query(&url, "id").unwrap_or_default(),
                    );
                    let found = self.store.attachments(task)?.into_iter().find(|a| a.id == id);
                    // R76: content that has not arrived is fetched from the storage now (S35);
                    // when it is not there either, the error says so and the page shows it.
                    let found = match found {
                        Some(a) if a.local_path.is_none() => Some(self.store.fetch_attachment(a.id)?),
                        other => other,
                    };
                    match found.as_ref().and_then(|a| a.local_path.as_ref().map(|p| (a, p))) {
                        Some((a, path)) => {
                            let name: String = a.name.chars().filter(|c| !c.is_control() && *c != '"').collect();
                            let name = encode_name(&name);
                            let shown = query(&url, "view").and(preview_kind(&a.mime));
                            let range = request
                                .headers()
                                .iter()
                                .find(|h| h.field.equiv("Range"))
                                .map(|h| h.value.as_str().to_string());
                            // R141: the file is sent from the disk, and one range of it when asked.
                            file_reply(Path::new(path), &a.mime, &name, shown.is_some(), range.as_deref())
                        }
                        None => fail(404, "no such attachment"),
                    }
                }
                (Method::Post, "/api/upload") => {
                    let task = query(&url, "task").unwrap_or_default();
                    let name = query(&url, "name")
                        .map(|n| n.replace(['/', '\\'], "_"))
                        .filter(|n| !n.is_empty())
                        .unwrap_or_else(|| "file".into());
                    let dir = std::env::temp_dir().join(format!("lists-upload-{}", uuid::Uuid::new_v4().simple()));
                    std::fs::create_dir_all(&dir).map_err(|e| AppError::Storage { msg: e.to_string() })?;
                    let file = dir.join("upload");
                    // R140: the body goes to the disk as it arrives; only the limit can stop it.
                    if let Err(r) = Self::save_body(request, &file, self.store.attachment_limits().max_file) {
                        let _ = std::fs::remove_dir_all(&dir);
                        return Ok(r);
                    }
                    let added = self.store.as_actor(&actor, || {
                        self.store
                            .add_attachment(task, file.to_string_lossy().into_owned(), Some(name))
                    });
                    let _ = std::fs::remove_dir_all(&dir);
                    self.dirty.store(true, Ordering::Relaxed);
                    json_reply(200, attachment_json(&added?))
                }
                (Method::Post, "/api/import") => {
                    let data = match Self::body(request) {
                        Ok(b) => b,
                        Err(r) => return Ok(r),
                    };
                    let dir = std::env::temp_dir().join(format!("lists-upload-{}", uuid::Uuid::new_v4().simple()));
                    std::fs::create_dir_all(&dir).map_err(|e| AppError::Storage { msg: e.to_string() })?;
                    // The name carries no meaning to the importer except as a Todoist or OmniFocus list name.
                    let name = query(&url, "name")
                        .map(|n| n.replace(['/', '\\'], "_"))
                        .filter(|n| !n.is_empty())
                        .unwrap_or_else(|| "import".into());
                    let file = dir.join(name);
                    std::fs::write(&file, data).map_err(|e| AppError::Storage { msg: e.to_string() })?;
                    let report = self.store.import_file(file.to_string_lossy().into_owned());
                    let _ = std::fs::remove_dir_all(&dir);
                    self.dirty.store(true, Ordering::Relaxed);
                    let report = report?;
                    json_reply(
                        200,
                        json!({ "source": report.source, "lists": report.lists, "tasks": report.tasks, "attachments": report.attachments, "notes": report.notes }),
                    )
                }
                (Method::Post, "/api/call") => {
                    let body = match Self::body(request) {
                        Ok(b) => b,
                        Err(r) => return Ok(r),
                    };
                    let args: Value =
                        serde_json::from_slice(&body).map_err(|e| AppError::Invalid { msg: e.to_string() })?;
                    let op = text_arg(&args, "op")?;
                    json_reply(200, self.store.as_actor(&actor, || self.call(&op, &args))?)
                }
                // R155, R156: the export as a file to save; everything, or one list.
                (Method::Get, "/api/export") => {
                    let markdown = query(&url, "format").as_deref() == Some("markdown");
                    let list = query(&url, "list").filter(|l| !l.is_empty());
                    let dir = std::env::temp_dir().join(format!("lists-export-{}", uuid::Uuid::new_v4().simple()));
                    std::fs::create_dir_all(&dir).map_err(|e| AppError::Storage { msg: e.to_string() })?;
                    let file = dir.join("export");
                    let path = file.to_string_lossy().into_owned();
                    let written = if markdown {
                        self.store.export_markdown(path, list)
                    } else {
                        self.store.export_json(path, list)
                    };
                    let data = written
                        .and_then(|()| std::fs::read(&file).map_err(|e| AppError::Storage { msg: e.to_string() }));
                    let _ = std::fs::remove_dir_all(&dir);
                    let day = chrono::Local::now().format("%Y-%m-%d");
                    let (kind, name) = if markdown {
                        ("text/markdown; charset=utf-8", format!("Lists-{day}.md"))
                    } else {
                        ("application/json", format!("Lists-{day}.json"))
                    };
                    reply(200, kind, data?)
                        .with_header(header(
                            "Content-Disposition",
                            &format!("attachment; filename=\"{name}\""),
                        ))
                        .with_header(header("Cache-Control", "no-store"))
                }
                (Method::Get, "/api/tokens") => json_reply(200, self.tokens.list()),
                (Method::Post, "/api/tokens") => {
                    let args = match Self::json_body(request) {
                        Ok(v) => v,
                        Err(r) => return Ok(r),
                    };
                    json_reply(200, self.tokens.create(&args)?)
                }
                (Method::Post, "/api/tokens/revoke") => {
                    let args = match Self::json_body(request) {
                        Ok(v) => v,
                        Err(r) => return Ok(r),
                    };
                    let known = self.tokens.revoke(args["id"].as_str().unwrap_or_default())?;
                    json_reply(200, json!({ "ok": true, "known": known }))
                }
                (Method::Get, "/api/notifications/key") => {
                    json_reply(200, json!({ "key": self.notifier.public_key() }))
                }
                (Method::Post, "/api/notifications/subscribe") => {
                    let args = match Self::json_body(request) {
                        Ok(v) => v,
                        Err(r) => return Ok(r),
                    };
                    json_reply(200, json!({ "settings": self.notifier.subscribe(&args)? }))
                }
                (Method::Post, "/api/notifications/unsubscribe") => {
                    let args = match Self::json_body(request) {
                        Ok(v) => v,
                        Err(r) => return Ok(r),
                    };
                    let known = self
                        .notifier
                        .unsubscribe(args["endpoint"].as_str().unwrap_or_default())?;
                    json_reply(200, json!({ "ok": true, "known": known }))
                }
                (Method::Post, "/api/notifications/test") => {
                    let args = match Self::json_body(request) {
                        Ok(v) => v,
                        Err(r) => return Ok(r),
                    };
                    let endpoint = args["endpoint"].as_str().unwrap_or_default();
                    match self.notifier.test(endpoint, chrono::Utc::now()) {
                        Some(notify::Sent::Ok) => json_reply(200, json!({ "ok": true })),
                        Some(notify::Sent::Gone) => fail(410, "the browser no longer has this subscription"),
                        Some(notify::Sent::Failed(e)) => fail(502, e),
                        None => fail(404, "this browser is not subscribed"),
                    }
                }
                (Method::Post, "/api/logout") => {
                    if let Some(token) = self.session(request) {
                        self.sessions.lock().unwrap_or_else(|p| p.into_inner()).remove(&token);
                    }
                    json_reply(200, json!({ "ok": true }))
                }
                _ => fail(404, "not found"),
            })
        };
        let result = match zone {
            Some(minutes) => self.store.in_zone(minutes, run),
            None => run(),
        };
        result.unwrap_or_else(|e| {
            let code = match e {
                AppError::NotFound { .. } => 404,
                AppError::Invalid { .. } => 400,
                AppError::Sync { .. } => 502,
                AppError::Storage { .. } => 500,
                // R140: the web answers a file above the limit of the device with 413.
                AppError::TooLarge { .. } => 413,
            };
            fail(code, e.to_string())
        })
    }
}

/// R141: what a `Range` header asks for. A range that cannot be understood is ignored, and the whole
/// file is a valid answer; a range outside the file is refused with 416.
enum Asked {
    Whole,
    Part { start: u64, end: u64 },
    NotSatisfiable,
}

fn asked_range(value: Option<&str>, size: u64) -> Asked {
    let Some(text) = value else {
        return Asked::Whole;
    };
    let Some(spec) = text.trim().strip_prefix("bytes=") else {
        return Asked::Whole;
    };
    // Several ranges at once are not needed by a browser: the whole file is a correct answer.
    if spec.contains(',') {
        return Asked::Whole;
    }
    let Some((start, end)) = spec.split_once('-') else {
        return Asked::Whole;
    };
    let (start, end) = (start.trim(), end.trim());
    let (start, end) = if start.is_empty() {
        // `-N`: the last N bytes.
        let Some(suffix) = end.parse::<u64>().ok().filter(|n| *n > 0) else {
            return Asked::Whole;
        };
        if size == 0 {
            return Asked::NotSatisfiable;
        }
        (size.saturating_sub(suffix), size - 1)
    } else {
        let Ok(start) = start.parse::<u64>() else {
            return Asked::Whole;
        };
        let end = if end.is_empty() {
            size.saturating_sub(1)
        } else {
            let Ok(end) = end.parse::<u64>() else {
                return Asked::Whole;
            };
            end
        };
        (start, end)
    };
    if size == 0 || start >= size || end < start {
        return Asked::NotSatisfiable;
    }
    Asked::Part {
        start,
        end: end.min(size - 1),
    }
}

/// R141: one attachment, sent from the disk: the whole file or one range of it.
fn file_reply(path: &Path, mime: &str, name: &str, inline: bool, range: Option<&str>) -> Reply {
    let size = match std::fs::metadata(path) {
        Ok(meta) => meta.len(),
        Err(_) => return fail(404, "no such attachment"),
    };
    let mut file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(e) => return fail(500, e.to_string()),
    };
    let (kind, disposition) = if inline {
        // Shown in place only for the types of `preview_kind`, under the declared type and nothing
        // else: the browser may not guess another one.
        (mime, format!("inline; filename*=UTF-8''{name}"))
    } else {
        // Never rendered in place: an uploaded HTML file must not run on this origin.
        (
            "application/octet-stream",
            format!("attachment; filename*=UTF-8''{name}"),
        )
    };
    let mut headers = vec![
        header("Content-Type", kind),
        header("Cache-Control", "no-store"),
        header("X-Content-Type-Options", "nosniff"),
        header("Referrer-Policy", "no-referrer"),
        header("Content-Disposition", &disposition),
        header("Accept-Ranges", "bytes"),
    ];
    if inline {
        headers.push(header("Content-Security-Policy", PREVIEW_POLICY));
    }
    match asked_range(range, size) {
        Asked::Whole => Response::new(
            200.into(),
            headers,
            Box::new(file) as Box<dyn Read + Send>,
            Some(size as usize),
            None,
        ),
        Asked::Part { start, end } => {
            if let Err(e) = file.seek(SeekFrom::Start(start)) {
                return fail(500, e.to_string());
            }
            let length = end - start + 1;
            headers.push(header("Content-Range", &format!("bytes {start}-{end}/{size}")));
            Response::new(
                206.into(),
                headers,
                Box::new(file.take(length)) as Box<dyn Read + Send>,
                Some(length as usize),
                None,
            )
        }
        Asked::NotSatisfiable => {
            let mut response = fail(416, "range not satisfiable");
            response.add_header(header("Content-Range", &format!("bytes */{size}")));
            response.add_header(header("Accept-Ranges", "bytes"));
            response
        }
    }
}

fn encode_name(name: &str) -> String {
    name.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_') {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

/// R144: asks the server listening on `listen` for `/healthz`. A wildcard address is asked on
/// loopback, which is where the check runs: inside the container, next to the server.
pub fn check_health(listen: &str) -> Result<(), String> {
    let addr = std::net::ToSocketAddrs::to_socket_addrs(listen)
        .map_err(|e| format!("{listen}: {e}"))?
        .next()
        .ok_or_else(|| format!("{listen}: no address"))?;
    let addr = match addr {
        SocketAddr::V4(a) if a.ip().is_unspecified() => SocketAddr::from(([127, 0, 0, 1], a.port())),
        SocketAddr::V6(a) if a.ip().is_unspecified() => SocketAddr::from((std::net::Ipv6Addr::LOCALHOST, a.port())),
        other => other,
    };
    let timeout = Duration::from_secs(5);
    let mut stream = std::net::TcpStream::connect_timeout(&addr, timeout).map_err(|e| format!("{addr}: {e}"))?;
    stream.set_read_timeout(Some(timeout)).map_err(|e| e.to_string())?;
    stream.set_write_timeout(Some(timeout)).map_err(|e| e.to_string())?;
    write!(stream, "GET /healthz HTTP/1.0\r\nHost: {addr}\r\n\r\n").map_err(|e| format!("{addr}: {e}"))?;
    let mut answer = Vec::new();
    stream
        .take(4096)
        .read_to_end(&mut answer)
        .map_err(|e| format!("{addr}: {e}"))?;
    let answer = String::from_utf8_lossy(&answer);
    let status = answer.lines().next().unwrap_or_default();
    if status.split(' ').nth(1) == Some("200") {
        Ok(())
    } else {
        Err(format!("{addr}: {status}"))
    }
}

/// Opens the store, starts the HTTP workers and the sync thread, and returns.
pub fn start(config: Config) -> Result<Running, Box<dyn std::error::Error>> {
    let data_dir = config.data_dir.clone();
    let store = Store::open(config.data_dir)?;
    // After the store, which makes the folder.
    let notifier = notify::Notifier::open(
        Path::new(&data_dir),
        config.vapid_subject.unwrap_or_else(|| VAPID_SUBJECT.into()),
    )?;
    let tokens = tokens::Tokens::open(Path::new(&data_dir))?;
    // R140: the limits of this server: what the environment gives, or the defaults. The environment
    // is the only place they are set here, so a removed variable brings its default back.
    store.set_attachment_limits(AttachmentLimits {
        max_file: config.max_file.unwrap_or(DEFAULT_MAX_FILE),
        max_task: config.max_task.unwrap_or(DEFAULT_MAX_TASK),
    })?;
    store.set_sync_config(config.sync)?;
    store.set_sync_password(config.sync_password);
    store.set_sync_passphrase(config.sync_passphrase);
    store.set_push_server(config.push_server)?;
    store.set_push_token(config.push_token);
    let server =
        Arc::new(Server::http(&config.listen).map_err(|e| format!("cannot listen on {}: {e}", config.listen))?);
    let addr = server.server_addr().to_ip().ok_or("not an IP address")?;
    let app = Arc::new(App {
        store,
        password: config.password,
        oidc: config.oidc.map(oidc::Oidc::new).transpose()?,
        sessions: Mutex::new(HashMap::new()),
        trust_proxy: config.trust_proxy,
        secure_cookie: config.secure_cookie,
        failures: Mutex::new(HashMap::new()),
        dirty: AtomicBool::new(true),
        notifier,
        tokens,
    });

    // R134: a thread for each request, as tiny_http has one for each connection, so a
    // request whose body never arrives holds only its own. The rest of a body that was
    // not read is drained when the request is dropped, on the thread that had it.
    // There is no read timeout: tiny_http does not reach the connections, and one on the
    // listening socket makes accept fail on Linux, which stops the server for good.
    {
        let app = app.clone();
        std::thread::spawn(move || {
            while let Ok(mut request) = server.recv() {
                let app = app.clone();
                let _ = std::thread::Builder::new().spawn(move || {
                    let response = app.handle(&mut request);
                    let _ = request.respond(response);
                });
            }
        });
    }

    // A nudge from another device is one more reason to sync. The call blocks
    // while there is nothing to hear and paces itself when the server is away.
    {
        let app = app.clone();
        std::thread::spawn(move || loop {
            if app.store.wait_for_nudge() {
                app.dirty.store(true, Ordering::Relaxed);
            }
        });
    }

    // R146: what came due is sent every half minute. The first look only marks the start.
    {
        let app = app.clone();
        std::thread::spawn(move || loop {
            app.notifier.tick(&app.store, chrono::Utc::now());
            std::thread::sleep(Duration::from_secs(30));
        });
    }

    // Like the apps: two seconds after a change, and once a minute regardless.
    // A sync folder is also watched for files brought in by another program.
    std::thread::spawn(move || {
        let mut idle = 0u32;
        let mut refused = false;
        loop {
            std::thread::sleep(Duration::from_secs(2));
            idle += 2;
            // S30: said once when it starts, not on every retry.
            if app.store.push_refused() != refused {
                refused = !refused;
                if refused {
                    eprintln!("lists-web: the push server refused access; check LISTS_PUSH_TOKEN");
                }
            }
            if app.dirty.swap(false, Ordering::Relaxed) || idle >= 60 || app.store.folder_changed() {
                idle = 0;
                // A failure is kept in the sync status, which the page shows.
                if app.store.sync_now().is_ok() {
                    move_attachments(&app.store);
                }
            }
        }
    });
    Ok(Running { addr })
}
