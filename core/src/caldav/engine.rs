//! One sync run against a CalDAV server. Rules: docs/specs/caldav.md.
//!
//! The order matters: lists first (a task needs its calendar), then everything
//! the server has that this device has not seen, then what disappeared, and
//! only then local changes go up.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use base64::Engine;
use rusqlite::{params, OptionalExtension};
use serde_json::{json, Value};
use uuid::Uuid;

use super::client::{Calendar, Client, Condition, Written};
use super::ical;
use super::map::{self, Registers, Remote, Standard, TaskState};
use crate::db::{self, Change, Touched, KIND_ATTACHMENT, KIND_FILTER, KIND_LIST, KIND_TASK};
use crate::error::Result;
use crate::hlc;
use crate::model::{Repeat, SyncReport, INBOX_ID};
use crate::store::{append_pos_in_list, complete_in, Store, Writer};

const INBOX_SLUG: &str = "lists-inbox";
const MAX_ID: usize = 200;

struct Item {
    href: String,
    calendar: String,
    etag: String,
    raw: String,
}

fn registers(conn: &rusqlite::Connection, kind: &str, id: &str) -> Result<Registers> {
    let mut stmt = conn.prepare_cached("SELECT field, value, stamp FROM fields WHERE kind = ?1 AND id = ?2")?;
    let rows = stmt.query_map(params![kind, id], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?))
    })?;
    let mut out = Registers::new();
    for row in rows {
        let (field, value, stamp) = row?;
        out.insert(field, (serde_json::from_str(&value).unwrap_or(Value::Null), stamp));
    }
    Ok(out)
}

fn task_state(conn: &rusqlite::Connection, id: &str) -> Result<TaskState> {
    let mut state = TaskState {
        fields: registers(conn, KIND_TASK, id)?,
        attachments: BTreeMap::new(),
    };
    let mut stmt = conn.prepare_cached("SELECT id FROM attachments WHERE task_id = ?1 ORDER BY id")?;
    let ids: Vec<String> = stmt.query_map([id], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
    for attachment in ids {
        state
            .attachments
            .insert(attachment.clone(), registers(conn, KIND_ATTACHMENT, &attachment)?);
    }
    Ok(state)
}

fn usable_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= MAX_ID && !id.chars().any(char::is_control)
}

/// The list a calendar stands for. Calendars this app created are named after
/// the list; any other gets an id derived from its address, the same on every device.
fn list_id_of(href: &str) -> String {
    let slug = href.trim_end_matches('/').rsplit('/').next().unwrap_or_default();
    if slug == INBOX_SLUG {
        INBOX_ID.to_string()
    } else if Uuid::parse_str(slug).is_ok() {
        slug.to_string()
    } else {
        Uuid::new_v5(&Uuid::NAMESPACE_URL, href.as_bytes()).to_string()
    }
}

/// File name of a task's object: its id when that is safe in a URL.
fn object_name(uid: &str) -> String {
    let safe = uid
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'));
    if safe && uid.len() <= 100 {
        format!("{uid}.ics")
    } else {
        format!("{}.ics", Uuid::new_v5(&Uuid::NAMESPACE_OID, uid.as_bytes()))
    }
}

fn encode_registers(registers: &Registers) -> String {
    base64::engine::general_purpose::STANDARD.encode(serde_json::to_vec(registers).unwrap_or_default())
}

fn decode_registers(value: &str) -> Option<Registers> {
    let json = base64::engine::general_purpose::STANDARD.decode(value.trim()).ok()?;
    let mut registers: Registers = serde_json::from_slice(&json).ok()?;
    registers.retain(|field, (_, stamp)| !field.is_empty() && hlc::is_valid(stamp));
    Some(registers)
}

fn text(registers: &Registers, field: &str) -> String {
    registers
        .get(field)
        .and_then(|(v, _)| v.as_str())
        .unwrap_or_default()
        .to_string()
}

/// `#RRGGBBAA` and lower case are the same colour as `#RRGGBB`.
fn color_key(color: &str) -> String {
    color.chars().take(7).collect::<String>().to_uppercase()
}

impl Store {
    /// Applies registers that came from the server; returns how many changed local state.
    fn apply_remote(&self, changes: Vec<Change>) -> Result<u32> {
        let mut inner = self.lock();
        let inner = &mut *inner;
        let tx = inner
            .conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let mut touched = Touched::new();
        let mut changed = 0;
        for change in changes.iter().filter(|c| c.is_well_formed()) {
            inner.clock.observe(&change.stamp);
            if db::apply(&tx, change, false, &mut touched)? {
                changed += 1;
            }
        }
        db::settle(&tx, &touched)?;
        tx.commit()?;
        Ok(changed)
    }

    fn item_by_uid(&self, uid: &str) -> Result<Option<Item>> {
        Ok(self
            .lock()
            .conn
            .query_row(
                "SELECT href, calendar, etag, raw FROM caldav_items WHERE uid = ?1",
                [uid],
                |r| {
                    Ok(Item {
                        href: r.get(0)?,
                        calendar: r.get(1)?,
                        etag: r.get(2)?,
                        raw: r.get(3)?,
                    })
                },
            )
            .optional()?)
    }

    fn save_item(&self, href: &str, calendar: &str, uid: &str, etag: &str, raw: &str) -> Result<()> {
        let inner = self.lock();
        // One object per task: a copy left behind in another calendar is forgotten.
        inner.conn.execute(
            "DELETE FROM caldav_items WHERE uid = ?1 AND href != ?2",
            params![uid, href],
        )?;
        inner.conn.execute(
            "INSERT INTO caldav_items (href, calendar, uid, etag, raw) VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT (href) DO UPDATE SET calendar = excluded.calendar, uid = excluded.uid, etag = excluded.etag, raw = excluded.raw",
            params![href, calendar, uid, etag, raw],
        )?;
        Ok(())
    }

    fn forget_item(&self, href: &str) -> Result<()> {
        self.lock()
            .conn
            .execute("DELETE FROM caldav_items WHERE href = ?1", [href])?;
        Ok(())
    }

    fn save_blobs(&self, calendar: &ical::Component) -> Result<u32> {
        let mut saved = 0;
        for (sha256, bytes) in map::blobs(calendar) {
            let path = self.blob_path(&sha256);
            if !path.exists() {
                let tmp = path.with_extension("part");
                std::fs::write(&tmp, &bytes)?;
                std::fs::rename(&tmp, &path)?;
                saved += 1;
            }
        }
        Ok(saved)
    }

    /// Brings one calendar's settings in: the app's own registers, then a name
    /// or colour changed by another client.
    fn merge_calendar(&self, list_id: &str, calendar: &Calendar) -> Result<u32> {
        let remote = calendar.state.as_deref().and_then(decode_registers);
        let known = !registers(&self.lock().conn, KIND_LIST, list_id)?.is_empty();
        let mut changed = match &remote {
            Some(registers) => self.apply_remote(
                registers
                    .iter()
                    .map(|(field, (value, stamp))| Change {
                        kind: KIND_LIST.into(),
                        id: list_id.into(),
                        field: field.clone(),
                        value: value.clone(),
                        stamp: stamp.clone(),
                    })
                    .collect(),
            )?,
            None => 0,
        };
        // What the standard properties are compared with: the state next to
        // them, or, without one, what this device already believes.
        let reference = match remote {
            Some(registers) => registers,
            None => registers(&self.lock().conn, KIND_LIST, list_id)?,
        };
        let is_inbox = list_id == INBOX_ID;
        let rename = !is_inbox && !calendar.name.is_empty() && calendar.name != text(&reference, "name");
        let recolor = !calendar.color.is_empty() && color_key(&calendar.color) != color_key(&text(&reference, "color"));
        if rename || recolor || !known {
            changed += self.write(|w| {
                let mut n = 0;
                if rename {
                    w.list(list_id, "name", json!(calendar.name))?;
                    n += 1;
                }
                if recolor {
                    w.list(list_id, "color", json!(color_key(&calendar.color)))?;
                    n += 1;
                }
                if !known && !is_inbox && !rename {
                    // A calendar seen for the first time with no usable name still becomes a list.
                    w.list(
                        list_id,
                        "name",
                        json!(if calendar.name.is_empty() {
                            "Calendar"
                        } else {
                            calendar.name.as_str()
                        }),
                    )?;
                    n += 1;
                }
                if !known && !is_inbox && text(&reference, "pos").is_empty() {
                    let last: Option<String> =
                        w.tx.query_row("SELECT max(pos) FROM lists WHERE id != 'inbox'", [], |r| r.get(0))?;
                    w.list(list_id, "pos", json!(crate::order::between(last.as_deref(), None)))?;
                }
                Ok(n)
            })?;
        }
        Ok(changed)
    }

    /// Brings one object in. Returns how many registers changed.
    fn merge_object(&self, list_id: &str, remote: &Remote) -> Result<u32> {
        let id = remote.uid.as_str();
        let known = !registers(&self.lock().conn, KIND_TASK, id)?.is_empty();
        let mut changed = 0;
        if let Some(state) = &remote.state {
            let mut changes: Vec<Change> = Vec::new();
            let mut push = |kind: &str, id: &str, registers: &Registers| {
                for (field, (value, stamp)) in registers {
                    changes.push(Change {
                        kind: kind.into(),
                        id: id.into(),
                        field: field.clone(),
                        value: value.clone(),
                        stamp: stamp.clone(),
                    });
                }
            };
            push(KIND_TASK, id, &state.fields);
            for (attachment, registers) in state.attachments.iter().filter(|(a, _)| usable_id(a)) {
                push(KIND_ATTACHMENT, attachment, registers);
            }
            changed += self.apply_remote(changes)?;
        }

        // C8, C9: standard properties that disagree with the reference are an
        // edit by another client and become new values.
        let reference = match &remote.state {
            Some(state) => Standard::of(state),
            None => Standard::of(&task_state(&self.lock().conn, id)?),
        };
        let stated_list = remote.state.as_ref().map(|s| text(&s.fields, "list"));
        let seen = &remote.standard;
        changed += self.write(|w| {
            let mut n = 0u32;
            let mut set = |w: &mut Writer, field: &str, value: Value| -> Result<()> {
                n += 1;
                w.task(id, field, value)
            };
            if seen.title != reference.title && !seen.title.is_empty() {
                set(w, "title", json!(seen.title))?;
            }
            if seen.notes != reference.notes {
                set(w, "notes", json!(seen.notes))?;
            }
            if seen.start != reference.start {
                set(w, "start", json!(seen.start))?;
            }
            if seen.due != reference.due {
                set(w, "due", json!(seen.due))?;
            }
            if seen.priority != reference.priority {
                set(w, "priority", json!(seen.priority))?;
            }
            for tag in seen.tags.difference(&reference.tags) {
                set(w, &format!("tag:{tag}"), json!(true))?;
            }
            for tag in reference.tags.difference(&seen.tags) {
                set(w, &format!("tag:{tag}"), json!(false))?;
            }
            if seen.parent != reference.parent && seen.parent.as_deref() != Some(id) {
                set(w, "parent", json!(seen.parent))?;
            }
            if !remote.foreign_rrule && seen.rrule != reference.rrule {
                let current: Option<Repeat> = registers(w.tx, KIND_TASK, id)?
                    .get("repeat")
                    .and_then(|(v, _)| serde_json::from_value(v.clone()).ok());
                let value = match &remote.repeat {
                    // Counting from completion has no standard form: keep the local choice.
                    Some(rule) => serde_json::to_value(Repeat {
                        from_done: current.is_some_and(|c| c.from_done),
                        ..rule.clone()
                    })?,
                    None => Value::Null,
                };
                set(w, "repeat", value)?;
            }
            // A task another client created, or moved to another calendar.
            let placed = match &stated_list {
                Some(list) => list == list_id,
                None => {
                    known
                        && w.tx
                            .query_row(
                                "SELECT eff_list = ?2 FROM tasks WHERE id = ?1",
                                params![id, list_id],
                                |r| r.get(0),
                            )
                            .optional()?
                            .unwrap_or(false)
                }
            };
            if !placed && seen.parent.is_none() {
                set(w, "list", json!(list_id))?;
            }
            if !known && remote.state.is_none() {
                let pos = append_pos_in_list(w.tx, list_id)?;
                set(w, "pos", json!(pos))?;
            }
            w.flush()?;
            if seen.done && !reference.done {
                let open_and_repeating: bool =
                    w.tx.query_row(
                        "SELECT done IS NULL AND repeat IS NOT NULL FROM tasks WHERE id = ?1",
                        [id],
                        |r| r.get(0),
                    )
                    .optional()?
                    .unwrap_or(false);
                if open_and_repeating {
                    // C11: completing one occurrence moves the task on.
                    complete_in(w, id)?;
                    n += 1;
                } else {
                    let moment = remote.completed.clone().unwrap_or_else(|| w.moment());
                    set(w, "done", json!(moment))?;
                }
            } else if !seen.done && reference.done {
                set(w, "done", Value::Null)?;
            }
            Ok(n)
        })?;
        Ok(changed)
    }
}

/// What the server holds for a list: name, colour and the app's own registers.
fn desired_props(list_id: &str, registers: &Registers) -> (String, String, String) {
    let name = text(registers, "name");
    let name = if list_id == INBOX_ID && name.is_empty() {
        "Inbox".to_string()
    } else {
        name
    };
    (name, text(registers, "color"), encode_registers(registers))
}

pub fn sync(store: &Store, client: &Client) -> Result<SyncReport> {
    let mut report = SyncReport::default();

    // ---- lists ↔ calendars ----
    let calendars = client.calendars()?;
    let mut calendar_of: HashMap<String, String> = HashMap::new();
    let mut seen_calendars: BTreeSet<String> = BTreeSet::new();
    for calendar in &calendars {
        let list_id = list_id_of(&calendar.href);
        if calendar_of.contains_key(&list_id) {
            continue;
        }
        report.pulled += store.merge_calendar(&list_id, calendar)?;
        calendar_of.insert(list_id.clone(), calendar.href.clone());
        seen_calendars.insert(calendar.href.clone());
    }
    let known_calendars: Vec<(String, String, Option<String>)> = {
        let inner = store.lock();
        let mut stmt = inner.conn.prepare("SELECT href, list_id, sent FROM caldav_calendars")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    for (href, list_id, _) in &known_calendars {
        if !seen_calendars.contains(href) {
            // The calendar was removed on the server: the list goes with it.
            if list_id != INBOX_ID {
                store.write(|w| w.list(list_id, "deleted", json!(true)))?;
                report.pulled += 1;
            }
            store
                .lock()
                .conn
                .execute("DELETE FROM caldav_calendars WHERE href = ?1", [href])?;
        }
    }
    let sent: HashMap<String, Option<String>> = known_calendars
        .into_iter()
        .map(|(href, _, sent)| (href, sent))
        .collect();
    let lists: Vec<(String, bool)> = {
        let inner = store.lock();
        let mut stmt = inner.conn.prepare("SELECT id, deleted FROM lists")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    for (list_id, deleted) in &lists {
        let regs = registers(&store.lock().conn, KIND_LIST, list_id)?;
        let (name, color, state) = desired_props(list_id, &regs);
        let href = match (calendar_of.get(list_id), deleted) {
            (Some(href), _) => href.clone(),
            (None, true) => continue,
            (None, false) => {
                let slug = if list_id == INBOX_ID {
                    INBOX_SLUG
                } else {
                    list_id.as_str()
                };
                let href = client.make_calendar(slug, &name, &color)?;
                calendar_of.insert(list_id.clone(), href.clone());
                report.pushed += 1;
                href
            }
        };
        if *deleted {
            continue;
        }
        let remote = calendars.iter().find(|c| c.href == href);
        let already_sent = sent.get(&href).cloned().flatten();
        let standard_differs =
            remote.is_none_or(|c| c.name != name || (!color.is_empty() && color_key(&c.color) != color_key(&color)));
        // A server that does not keep the property is not asked again with the same value.
        let state_differs = match remote.and_then(|c| c.state.as_deref()) {
            Some(theirs) => decode_registers(theirs).as_ref() != Some(&regs),
            None => already_sent.as_deref() != Some(state.as_str()),
        };
        if standard_differs || state_differs {
            client.set_props(&href, &name, &color, Some(&state))?;
            if remote.is_some() {
                report.pushed += 1;
            }
        }
        store.lock().conn.execute(
            "INSERT INTO caldav_calendars (href, list_id, sent) VALUES (?1, ?2, ?3)
             ON CONFLICT (href) DO UPDATE SET list_id = excluded.list_id, sent = excluded.sent",
            params![href, list_id, state],
        )?;
    }

    // ---- saved filters: a property of the inbox calendar ----
    if let Some(inbox) = calendar_of.get(INBOX_ID) {
        let theirs: BTreeMap<String, Registers> = calendars
            .iter()
            .find(|c| c.href == *inbox)
            .and_then(|c| c.filters.as_deref())
            .and_then(|raw| base64::engine::general_purpose::STANDARD.decode(raw.trim()).ok())
            .and_then(|json| serde_json::from_slice(&json).ok())
            .unwrap_or_default();
        let mut changes = Vec::new();
        for (id, registers) in theirs.iter().filter(|(id, _)| usable_id(id)) {
            for (field, (value, stamp)) in registers {
                changes.push(Change {
                    kind: KIND_FILTER.into(),
                    id: id.clone(),
                    field: field.clone(),
                    value: value.clone(),
                    stamp: stamp.clone(),
                });
            }
        }
        report.pulled += store.apply_remote(changes)?;
        let ours: BTreeMap<String, Registers> = {
            let inner = store.lock();
            let ids: Vec<String> = {
                let mut stmt = inner
                    .conn
                    .prepare("SELECT DISTINCT id FROM fields WHERE kind = ?1 ORDER BY id")?;
                let rows = stmt.query_map([KIND_FILTER], |r| r.get(0))?;
                rows.collect::<rusqlite::Result<_>>()?
            };
            ids.into_iter()
                .map(|id| registers(&inner.conn, KIND_FILTER, &id).map(|r| (id, r)))
                .collect::<Result<_>>()?
        };
        if ours != theirs {
            let encoded =
                base64::engine::general_purpose::STANDARD.encode(serde_json::to_vec(&ours).unwrap_or_default());
            // A server that drops the property is not asked again with the same value.
            let already = db::meta_get(&store.lock().conn, "caldav_filters_sent")?;
            if already.as_deref() != Some(encoded.as_str()) {
                client.set_filters(inbox, &encoded);
                db::meta_set(&store.lock().conn, "caldav_filters_sent", &encoded)?;
                report.pushed += 1;
            }
        }
    }

    // ---- objects the server has ----
    let mut listed: BTreeSet<String> = BTreeSet::new();
    let mut seen_uids: BTreeSet<String> = BTreeSet::new();
    for (list_id, calendar) in &calendar_of {
        for (href, etag) in client.list(calendar)? {
            listed.insert(href.clone());
            let known: Option<(String, String)> = store
                .lock()
                .conn
                .query_row("SELECT etag, uid FROM caldav_items WHERE href = ?1", [&href], |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })
                .optional()?;
            if let Some((known_etag, uid)) = &known {
                if !etag.is_empty() && *known_etag == etag {
                    seen_uids.insert(uid.clone());
                    continue;
                }
            }
            let Some((body, fresh_etag)) = client.get(&href)? else {
                listed.remove(&href);
                continue;
            };
            let Some(parsed) = ical::parse(&body) else {
                continue;
            };
            let Some(remote) = map::read(&parsed).filter(|r| usable_id(&r.uid)) else {
                continue; // an event, or something this app cannot identify
            };
            report.pulled += store.merge_object(list_id, &remote)?;
            report.blobs_downloaded += store.save_blobs(&parsed)?;
            let etag = if fresh_etag.is_empty() { etag } else { fresh_etag };
            store.save_item(&href, calendar, &remote.uid, &etag, &body)?;
            seen_uids.insert(remote.uid);
        }
    }

    // ---- objects that disappeared (C14) ----
    let stored: Vec<(String, String)> = {
        let inner = store.lock();
        let mut stmt = inner.conn.prepare("SELECT href, uid FROM caldav_items")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    for (href, uid) in stored {
        if listed.contains(&href) {
            continue;
        }
        store.forget_item(&href)?;
        if seen_uids.contains(&uid) {
            continue; // the same task now lives under another address
        }
        let live: bool = store
            .lock()
            .conn
            .query_row(
                "SELECT deleted = 0 AND purged = 0 FROM tasks WHERE id = ?1",
                [&uid],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or(false);
        if live {
            store.write(|w| w.task(&uid, "deleted", json!(true)))?;
            report.pulled += 1;
        }
    }

    // ---- local changes go up ----
    let tasks: Vec<(String, String, bool)> = {
        let inner = store.lock();
        let mut stmt = inner
            .conn
            .prepare("SELECT id, eff_list, eff_deleted OR purged FROM tasks ORDER BY id")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    let now = chrono::Utc::now().naive_utc();
    let blob = |sha: &str| std::fs::read(store.blob_path(sha)).ok();
    for (id, list_id, gone) in tasks {
        let item = store.item_by_uid(&id)?;
        if gone {
            // C6: a task in the trash is not kept on the server.
            if let Some(item) = item {
                if client.delete(&item.href, Some(&item.etag))? {
                    store.forget_item(&item.href)?;
                    report.pushed += 1;
                } else {
                    // Changed on the server meanwhile: read it again on the next run.
                    store.save_item(&item.href, &item.calendar, &id, "", &item.raw)?;
                }
            }
            continue;
        }
        let Some(calendar) = calendar_of.get(&list_id) else {
            continue;
        };
        let mut item = item;
        if let Some(old) = item.as_ref().filter(|i| i.calendar != *calendar) {
            // The task moved to another list: its object moves to that calendar.
            client.delete(&old.href, Some(&old.etag))?;
            store.forget_item(&old.href)?;
            item = None;
        }
        let href = item
            .as_ref()
            .map_or_else(|| format!("{calendar}{}", object_name(&id)), |i| i.href.clone());
        let mut base = item.as_ref().and_then(|i| ical::parse(&i.raw));
        let mut etag = item.as_ref().map(|i| i.etag.clone());
        // C13: on a refusal, read what is there, merge and try once more.
        for attempt in 0..2 {
            let state = task_state(&store.lock().conn, &id)?;
            let rendered = map::render(&id, &state, base.as_ref(), &blob, now);
            if base
                .as_ref()
                .is_some_and(|b| map::fingerprint(b) == map::fingerprint(&rendered))
            {
                break; // C16: nothing to say
            }
            let body = ical::serialize(&rendered);
            let condition = match etag.as_deref() {
                Some(e) if !e.is_empty() => Condition::Match(e),
                Some(_) => Condition::None,
                None => Condition::New,
            };
            match client.put(&href, &body, condition)? {
                Written::Done(new_etag) => {
                    store.save_item(&href, calendar, &id, new_etag.as_deref().unwrap_or(""), &body)?;
                    report.pushed += 1;
                    let managed = |c: Option<&ical::Component>| -> BTreeSet<String> {
                        c.and_then(|c| c.sub("VTODO"))
                            .map(|t| {
                                t.all("ATTACH")
                                    .filter_map(|p| p.param(map::SHA_PARAM).map(str::to_string))
                                    .collect()
                            })
                            .unwrap_or_default()
                    };
                    report.blobs_uploaded +=
                        managed(Some(&rendered)).difference(&managed(base.as_ref())).count() as u32;
                    break;
                }
                Written::Conflict if attempt == 0 => {
                    let Some((fresh, fresh_etag)) = client.get(&href)? else {
                        base = None;
                        etag = None;
                        continue;
                    };
                    let parsed = ical::parse(&fresh);
                    if let Some(remote) = parsed.as_ref().and_then(map::read).filter(|r| r.uid == id) {
                        report.pulled += store.merge_object(&list_id, &remote)?;
                    }
                    store.save_item(&href, calendar, &id, &fresh_etag, &fresh)?;
                    base = parsed;
                    etag = Some(fresh_etag);
                }
                Written::Conflict => break, // settled on the next run
            }
        }
    }

    // ---- lists removed here: the calendar goes once it is empty (C15) ----
    for (list_id, deleted) in &lists {
        if !*deleted || list_id == INBOX_ID {
            continue;
        }
        if let Some(href) = calendar_of.get(list_id) {
            if client.list(href)?.is_empty() && client.delete(href, None)? {
                store
                    .lock()
                    .conn
                    .execute("DELETE FROM caldav_calendars WHERE href = ?1", [href])?;
                report.pushed += 1;
            }
        }
    }
    Ok(report)
}
