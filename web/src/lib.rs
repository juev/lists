//! Web interface for Lists.
//!
//! The server is one more device: it keeps its own copy of the data, syncs it
//! like the apps do, and shows it to a browser. A browser cannot talk to a
//! WebDAV or CalDAV server on another origin, so this is what makes Lists
//! reachable from a phone without a native app.

mod oidc;

use std::collections::HashMap;
use std::io::Read;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub use oidc::OidcConfig;

use lists_core::{
    markdown_layout, AppError, Attachment, FilterSpec, KeepDone, MarkdownAlign, MarkdownKind, NewTask, Priority,
    Repeat, Scope, SortMode, Store, SyncConfig, TaskItem, TaskList,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tiny_http::{Header, Method, Request, Response, Server};

const INDEX: &str = include_str!("index.html");
const MANIFEST: &str = include_str!("manifest.json");
const ICON: &str = include_str!("icon.svg");
// Bitmaps for what cannot use the SVG: the iOS home screen, the install
// prompt, and browsers that only take a PNG for the tab.
const ICON_32: &[u8] = include_bytes!("icon-32.png");
const ICON_180: &[u8] = include_bytes!("icon-180.png");
const ICON_192: &[u8] = include_bytes!("icon-192.png");
const ICON_512: &[u8] = include_bytes!("icon-512.png");
const COOKIE: &str = "lists_session";
/// Request bodies above this are refused; it bounds one uploaded attachment.
const MAX_BODY: usize = 64 * 1024 * 1024;
const SESSION_TTL: Duration = Duration::from_secs(30 * 24 * 3600);

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
    /// ntfy server through which other devices ask this one to sync.
    pub push_server: Option<String>,
    /// Access token for that server, when it requires sign-in (S27).
    pub push_token: Option<String>,
}

struct App {
    store: Arc<Store>,
    password: Option<String>,
    oidc: Option<oidc::Oidc>,
    /// Session token → when it stops being valid.
    sessions: Mutex<HashMap<String, Instant>>,
    /// Set by a change, cleared by the sync thread.
    dirty: AtomicBool,
}

pub struct Running {
    pub addr: SocketAddr,
}

type Reply = Response<std::io::Cursor<Vec<u8>>>;

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
        "priority": priority_to(t.priority), "tags": t.tags,
        "repeat": t.repeat.as_ref().and_then(|r| serde_json::to_value(r).ok()),
        "remind": t.remind, "done": t.done, "wont": t.wont, "deleted": t.deleted, "log": t.is_log,
        "project": t.is_project,
        "subtasks": t.subtasks_total, "subtasksDone": t.subtasks_done, "attachments": t.attachments,
    })
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
                            &s.quick_add_under(text_arg(a, "text")?, project.to_string())?,
                        ));
                    }
                    // The view gives a task its list and nothing else (R75).
                    task_json(&s.quick_add(text_arg(a, "text")?, list)?)
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
        header(
            "Set-Cookie",
            &format!(
                "{COOKIE}={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={}",
                SESSION_TTL.as_secs()
            ),
        )
    }

    fn authorized(&self, request: &Request) -> bool {
        (self.password.is_none() && self.oidc.is_none()) || self.session(request).is_some()
    }

    fn body(request: &mut Request) -> Result<Vec<u8>, Reply> {
        if request.body_length().is_some_and(|n| n > MAX_BODY) {
            return Err(fail(413, "too large"));
        }
        let mut data = Vec::new();
        request
            .as_reader()
            .take(MAX_BODY as u64 + 1)
            .read_to_end(&mut data)
            .map_err(|e| fail(400, e.to_string()))?;
        if data.len() > MAX_BODY {
            return Err(fail(413, "too large"));
        }
        Ok(data)
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
            (Method::Get, "/manifest.json") => return reply(200, "application/manifest+json", MANIFEST),
            (Method::Get, "/icon.svg") => return reply(200, "image/svg+xml", ICON),
            (Method::Get, "/icon-32.png") | (Method::Get, "/favicon.ico") => return reply(200, "image/png", ICON_32),
            (Method::Get, "/icon-180.png") | (Method::Get, "/apple-touch-icon.png") => {
                return reply(200, "image/png", ICON_180)
            }
            (Method::Get, "/icon-192.png") => return reply(200, "image/png", ICON_192),
            (Method::Get, "/icon-512.png") => return reply(200, "image/png", ICON_512),
            (Method::Post, "/api/login") => {
                let body = match Self::body(request) {
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
                    // Slows down guessing.
                    std::thread::sleep(Duration::from_millis(800));
                    return fail(401, "wrong password");
                }
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
        if !self.authorized(request) {
            return fail(401, "login required");
        }
        // A cross-site form cannot set this header; together with SameSite it rules out CSRF.
        if method == Method::Post && !request.headers().iter().any(|h| h.field.equiv("X-Lists")) {
            return fail(400, "missing X-Lists header");
        }
        let result: Result<Reply, AppError> = (|| {
            Ok(match (&method, path.as_str()) {
                (Method::Get, "/api/overview") => json_reply(200, self.overview()?),
                (Method::Get, "/api/tasks") => {
                    let scope = query(&url, "scope")
                        .and_then(|s| scope_from(&s))
                        .ok_or_else(|| AppError::Invalid {
                            msg: "bad scope".into(),
                        })?;
                    json_reply(
                        200,
                        json!(self.store.tasks(scope)?.iter().map(task_json).collect::<Vec<_>>()),
                    )
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
                (Method::Get, "/api/file") => {
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
                            let data = std::fs::read(path).map_err(|e| AppError::Storage { msg: e.to_string() })?;
                            let name: String = a.name.chars().filter(|c| !c.is_control() && *c != '"').collect();
                            let name = encode_name(&name);
                            let shown = query(&url, "view").and(preview_kind(&a.mime));
                            match shown {
                                // Shown in place only for the types of `preview_kind`, under the declared
                                // type and nothing else: the browser may not guess another one.
                                Some(_) => reply(200, &a.mime, data)
                                    .with_header(header(
                                        "Content-Disposition",
                                        &format!("inline; filename*=UTF-8''{name}"),
                                    ))
                                    .with_header(header("Content-Security-Policy", PREVIEW_POLICY)),
                                // Never rendered in place: an uploaded HTML file must not run on this origin.
                                None => reply(200, "application/octet-stream", data).with_header(header(
                                    "Content-Disposition",
                                    &format!("attachment; filename*=UTF-8''{name}"),
                                )),
                            }
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
                    let data = match Self::body(request) {
                        Ok(b) => b,
                        Err(r) => return Ok(r),
                    };
                    let dir = std::env::temp_dir().join(format!("lists-upload-{}", uuid::Uuid::new_v4().simple()));
                    std::fs::create_dir_all(&dir).map_err(|e| AppError::Storage { msg: e.to_string() })?;
                    let file = dir.join("upload");
                    std::fs::write(&file, data).map_err(|e| AppError::Storage { msg: e.to_string() })?;
                    let added = self
                        .store
                        .add_attachment(task, file.to_string_lossy().into_owned(), Some(name));
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
                    // The name carries no meaning to the importer except as a Todoist list name.
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
                    json_reply(200, self.call(&op, &args)?)
                }
                (Method::Post, "/api/logout") => {
                    if let Some(token) = self.session(request) {
                        self.sessions.lock().unwrap_or_else(|p| p.into_inner()).remove(&token);
                    }
                    json_reply(200, json!({ "ok": true }))
                }
                _ => fail(404, "not found"),
            })
        })();
        result.unwrap_or_else(|e| {
            let code = match e {
                AppError::NotFound { .. } => 404,
                AppError::Invalid { .. } => 400,
                AppError::Sync { .. } => 502,
                AppError::Storage { .. } => 500,
            };
            fail(code, e.to_string())
        })
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

/// Opens the store, starts the HTTP workers and the sync thread, and returns.
pub fn start(config: Config) -> Result<Running, Box<dyn std::error::Error>> {
    let store = Store::open(config.data_dir)?;
    store.set_sync_config(config.sync)?;
    store.set_sync_password(config.sync_password);
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
        dirty: AtomicBool::new(true),
    });

    for _ in 0..4 {
        let (server, app) = (server.clone(), app.clone());
        std::thread::spawn(move || {
            while let Ok(mut request) = server.recv() {
                let response = app.handle(&mut request);
                let _ = request.respond(response);
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
