//! Import from other task managers. Formats and what is known about each:
//! docs/specs/import.md.
//!
//! Every importer turns its source into the same small model, which is then
//! written as ordinary local changes. Ids are derived from the ids in the
//! source, so importing the same file twice updates instead of duplicating.

use std::collections::{BTreeMap, HashMap};
use std::io::Read;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Local, NaiveDate, NaiveDateTime, TimeZone, Utc};
use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::db::{KIND_ATTACHMENT, KIND_LIST, KIND_TASK};
use crate::error::{AppError, Result};
use crate::model::{Freq, Repeat, INBOX_ID};
use crate::store::{hex, Store};
use crate::LogLevel;
use crate::{order, quickadd};

#[derive(Debug, Clone, PartialEq, Default, uniffi::Record)]
pub struct ImportReport {
    /// Name of the recognised format.
    pub source: String,
    pub lists: u32,
    pub tasks: u32,
    pub attachments: u32,
    /// What could not be carried over, in words meant for the user.
    pub notes: Vec<String>,
}

#[derive(Default)]
struct List {
    key: String,
    name: String,
    color: String,
}

#[derive(Default)]
struct Task {
    key: String,
    /// `None` is the inbox.
    list: Option<String>,
    parent: Option<String>,
    title: String,
    notes: String,
    start: Option<String>,
    due: Option<String>,
    remind: Option<String>,
    priority: i64,
    tags: Vec<String>,
    done: Option<String>,
    project: bool,
    repeat: Option<Repeat>,
    files: Vec<(String, PathBuf)>,
}

#[derive(Default)]
struct Parsed {
    source: &'static str,
    lists: Vec<List>,
    tasks: Vec<Task>,
    notes: Vec<String>,
}

fn invalid(msg: impl Into<String>) -> AppError {
    AppError::invalid(msg)
}

fn local_moment(utc: DateTime<Utc>) -> String {
    utc.with_timezone(&Local).format("%Y-%m-%dT%H:%M").to_string()
}

fn rule(freq: Freq, interval: u32) -> Repeat {
    Repeat {
        freq,
        interval: interval.max(1),
        weekdays: vec![],
        monthday: None,
        nth: None,
        nth_weekday: None,
        from_done: false,
        count: None,
        until: None,
    }
}

// ---------------------------------------------------------------- 2Do

/// Dates at or beyond this mean "none" in a 2Do database.
const TWODO_NO_DATE: f64 = 6_000_000_000.0;
const TWODO_TAG_SEPARATOR: &str = "_~|$$@$$|~_";

/// A due date: the day is a UTC instant on that day (noon), the time of day
/// is a separate number written as HHMM (930 is 09:30, 999999 is "no time").
fn twodo_date(seconds: f64, time_of_day: f64) -> Option<String> {
    if seconds <= 0.0 || seconds >= TWODO_NO_DATE {
        return None;
    }
    let date = Utc.timestamp_opt(seconds as i64, 0).single()?.date_naive();
    let (h, m) = ((time_of_day as i64) / 100, (time_of_day as i64) % 100);
    if (0.0..2400.0).contains(&time_of_day) && h < 24 && m < 60 {
        return Some(format!("{}T{h:02}:{m:02}", date.format("%Y-%m-%d")));
    }
    Some(date.format("%Y-%m-%d").to_string())
}

/// A start date: one instant whose UTC fields are the local date and time;
/// midnight means "no time".
fn twodo_start(seconds: f64) -> Option<String> {
    if seconds <= 0.0 || seconds >= TWODO_NO_DATE {
        return None;
    }
    let moment = Utc.timestamp_opt(seconds as i64, 0).single()?.naive_utc();
    let format = if moment.time() == chrono::NaiveTime::MIN {
        "%Y-%m-%d"
    } else {
        "%Y-%m-%dT%H:%M"
    };
    Some(moment.format(format).to_string())
}

/// The repeat rule of a 2Do task. Every code here was read from tasks created
/// in 2Do 4.19 with a known rule; the table is in docs/specs/import.md.
///
/// - 1..=127: weekly on chosen weekdays, one bit per day (Sunday 1, Saturday 2,
///   Friday 4, Thursday 8, Wednesday 16, Tuesday 32, Monday 64);
/// - 256..=259: every `value` days, weeks, months, years (2Do's Daily, Weekly,
///   Monthly and Yearly presets are stored this way with the value 1);
/// - 260..=266: the n-th weekday of each month, Monday 260 to Sunday 266, with
///   `value` 1 to 5 for the ordinal and 6 for "last".
///
/// `mode` 2 counts from the completion date. `end` is the end type (1 on a
/// date, 2 after a number of repeats), the repeats left, and the end date.
fn twodo_repeat(kind: i64, value: i64, mode: i64, end: (i64, i64, f64), due: Option<NaiveDate>) -> Option<Repeat> {
    let mut out = match kind {
        1..=127 => {
            // Monday first, as the rest of the app counts them.
            let bits = [64, 32, 16, 8, 4, 2, 1];
            let days: Vec<u32> = (0..7).filter(|i| kind & bits[*i] != 0).map(|i| i as u32 + 1).collect();
            let same_as_due = due.is_some_and(|d| days == [chrono::Datelike::weekday(&d).number_from_monday()]);
            // "Every week on the weekday of the due date" is the plain weekly rule.
            Repeat {
                weekdays: if same_as_due { vec![] } else { days },
                ..rule(Freq::Weekly, value.clamp(1, 999) as u32)
            }
        }
        256..=259 if (1..=999).contains(&value) => {
            let freq = [Freq::Daily, Freq::Weekly, Freq::Monthly, Freq::Yearly][(kind - 256) as usize];
            rule(freq, value as u32)
        }
        260..=266 if (1..=6).contains(&value) => Repeat {
            nth: Some(if value == 6 { -1 } else { value as i32 }),
            nth_weekday: Some((kind - 259) as u32),
            ..rule(Freq::Monthly, 1)
        },
        _ => return None,
    };
    out.from_done = mode == 2;
    match end {
        (1, _, date) => out.until = twodo_date(date, -1.0),
        (2, left, _) if left > 0 => out.count = Some(left as u32),
        _ => {}
    }
    Some(out)
}

/// A `.2dodb` backup: a zip with `2do.db` (SQLite) and the attachment files.
fn parse_2do(archive: &Path, work: &Path) -> Result<Parsed> {
    let file = std::fs::File::open(archive)?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| invalid(format!("not a 2Do backup: {e}")))?;
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|e| invalid(e.to_string()))?;
        // `enclosed_name` refuses paths that would leave the folder.
        let Some(relative) = entry.enclosed_name() else {
            continue;
        };
        let target = work.join(relative);
        if entry.is_dir() {
            std::fs::create_dir_all(&target)?;
            continue;
        }
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut out = std::fs::File::create(&target)?;
        std::io::copy(&mut entry, &mut out)?;
    }
    let db = work.join("2do.db");
    if !db.exists() {
        return Err(invalid("the backup has no 2do.db inside"));
    }
    let conn = Connection::open_with_flags(&db, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let mut out = Parsed {
        source: "2Do",
        ..Parsed::default()
    };

    // Ordinary lists only: listtype 0. Focus lists and smart lists are views, not containers.
    let mut inbox_uid = String::new();
    {
        let mut stmt = conn.prepare(
            "SELECT uid, coalesce(title, ''), coalesce(colorhex, ''), isinboxcal FROM calendars
             WHERE isdeleted = 0 AND (listtype = 0 OR isinboxcal = 1) AND coalesce(smartsearch, '') = '' ORDER BY displayorder",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, bool>(3)?,
            ))
        })?;
        for row in rows {
            let (uid, name, color, inbox) = row?;
            if inbox {
                inbox_uid = uid;
            } else {
                out.lists.push(List { key: uid, name, color });
            }
        }
    }
    let known: HashMap<&str, ()> = out.lists.iter().map(|l| (l.key.as_str(), ())).collect();

    let mut files: HashMap<String, Vec<(String, PathBuf)>> = HashMap::new();
    if let Ok(mut stmt) = conn.prepare(
        "SELECT taskuid, coalesce(displayname, ''), coalesce(fileextension, ''), relativepath FROM taskattachments
         WHERE isdeleted = 0 AND relativepath IS NOT NULL ORDER BY orderindex",
    ) {
        let rows = stmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
            ))
        })?;
        for row in rows {
            let (task, name, ext, relative) = row?;
            if relative.split('/').any(|p| p == ".." || p.is_empty()) {
                continue;
            }
            let path = work.join("2DoBackupPayload/Attachments").join(&relative);
            // 2Do keeps the extension apart from the name: a photo is "Image" with "jpg" beside it (I8).
            let name = if name.is_empty() {
                format!("attachment.{ext}")
            } else if ext.is_empty() || name.to_lowercase().ends_with(&format!(".{}", ext.to_lowercase())) {
                name
            } else {
                format!("{name}.{ext}")
            };
            if path.is_file() {
                files.entry(task).or_default().push((name, path));
            }
        }
    }

    let (mut repeats, mut converted, mut odd_priority) = (0u32, 0u32, 0u32);
    let mut stmt = conn.prepare(
        "SELECT uid, calendaruid, title, coalesce(notes, ''), duedate, coalesce(duetime, 999999), startdate, priority,
                iscompleted, coalesce(completeddate, 0), coalesce(tags, ''), coalesce(parent, ''), tasktype, repeattype, coalesce(url, ''),
                repeatvalue, recurrence, recurrenceendtype, recurrenceendrepeats, recurrenceenddate
         FROM tasks WHERE isdeleted = 0 ORDER BY displayorder, primid",
    )?;
    let mut rows = stmt.query([])?;
    while let Some(r) = rows.next()? {
        let uid: String = r.get(0)?;
        let calendar: String = r.get(1)?;
        let mut task = Task {
            list: (calendar != inbox_uid && known.contains_key(calendar.as_str())).then_some(calendar),
            title: r.get(2)?,
            notes: r.get(3)?,
            due: twodo_date(r.get::<_, f64>(4)?, r.get::<_, f64>(5)?),
            start: twodo_start(r.get::<_, f64>(6)?),
            files: files.remove(&uid).unwrap_or_default(),
            ..Task::default()
        };
        // The scale of iCalendar: 1 is the highest. 2Do writes 1, 5 and 9, and 10 for "none".
        task.priority = match r.get::<_, i64>(7)? {
            1..=4 => 3,
            5 => 2,
            6..=9 => 1,
            0 | 10 => 0,
            _ => {
                odd_priority += 1;
                0
            }
        };
        if r.get::<_, bool>(8)? {
            let at: f64 = r.get(9)?;
            let when = Utc
                .timestamp_opt(at as i64, 0)
                .single()
                .filter(|_| at > 0.0)
                .unwrap_or_else(Utc::now);
            task.done = Some(local_moment(when));
        }
        // One tag is eight fields; the first is its name.
        let tags: String = r.get(10)?;
        task.tags = tags
            .split(TWODO_TAG_SEPARATOR)
            .step_by(8)
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .map(str::to_string)
            .collect();
        let parent: String = r.get(11)?;
        task.parent = (!parent.is_empty()).then_some(parent);
        // 2 is a project, 1 a checklist; a checklist becomes a plain task with subtasks.
        task.project = r.get::<_, i64>(12)? == 2;
        let repeat_type: i64 = r.get(13)?;
        if repeat_type != 0 {
            let end = (r.get::<_, i64>(17)?, r.get::<_, i64>(18)?, r.get::<_, f64>(19)?);
            let due_day = task
                .due
                .as_deref()
                .or(task.start.as_deref())
                .and_then(|d| NaiveDate::parse_from_str(&d[..10], "%Y-%m-%d").ok());
            match twodo_repeat(repeat_type, r.get(15)?, r.get(16)?, end, due_day) {
                Some(rule) => {
                    converted += 1;
                    task.repeat = Some(crate::recur::normalized(
                        rule,
                        task.due.as_deref().or(task.start.as_deref()),
                    ));
                }
                None => {
                    repeats += 1;
                    task.tags.push("2do-repeat".into());
                }
            }
        }
        let url: String = r.get(14)?;
        if !url.is_empty() && !task.notes.contains(&url) {
            task.notes = format!("{}\n{url}", task.notes).trim().to_string();
        }
        task.key = uid;
        out.tasks.push(task);
    }
    if converted > 0 {
        out.notes.push(format!("{converted} repeat rules were converted."));
    }
    if repeats > 0 {
        out.notes.push(format!(
            "{repeats} repeating tasks use a rule this importer does not know; they were tagged #2do-repeat: set the repeat again."
        ));
    }
    if odd_priority > 0 {
        out.notes.push(format!(
            "{odd_priority} tasks had a priority value this importer does not know; it was left unset."
        ));
    }
    out.notes
        .push("Alarms, locations, actions, smart lists and list groups are not imported.".into());
    Ok(out)
}

// ---------------------------------------------------------------- Todoist

/// Minimal CSV reader: quoted fields, doubled quotes, line breaks inside quotes.
fn csv(text: &str) -> Vec<Vec<String>> {
    let mut rows = Vec::new();
    let (mut row, mut field, mut quoted) = (Vec::new(), String::new(), false);
    let mut chars = text.trim_start_matches('\u{feff}').chars().peekable();
    while let Some(c) = chars.next() {
        match (c, quoted) {
            ('"', true) if chars.peek() == Some(&'"') => {
                field.push('"');
                chars.next();
            }
            ('"', _) => quoted = !quoted,
            (',', false) => row.push(std::mem::take(&mut field)),
            ('\r', false) => {}
            ('\n', false) => {
                row.push(std::mem::take(&mut field));
                rows.push(std::mem::take(&mut row));
            }
            (c, _) => field.push(c),
        }
    }
    if !field.is_empty() || !row.is_empty() {
        row.push(field);
        rows.push(row);
    }
    rows
}

/// A Todoist project exported as a CSV template.
fn parse_todoist(text: &str, name: &str) -> Result<Parsed> {
    let rows = csv(text);
    let header: Vec<String> = rows
        .first()
        .ok_or_else(|| invalid("empty file"))?
        .iter()
        .map(|h| h.trim().to_uppercase())
        .collect();
    let col = |name: &str| header.iter().position(|h| h == name);
    let (Some(kind), Some(content)) = (col("TYPE"), col("CONTENT")) else {
        return Err(invalid("not a Todoist CSV: no TYPE and CONTENT columns"));
    };
    let get = |row: &Vec<String>, index: Option<usize>| {
        index
            .and_then(|i| row.get(i))
            .map(|s| s.trim().to_string())
            .unwrap_or_default()
    };
    let mut out = Parsed {
        source: "Todoist",
        ..Parsed::default()
    };
    out.lists.push(List {
        key: name.to_string(),
        name: name.to_string(),
        color: String::new(),
    });
    let today = Local::now().date_naive();
    let mut stack: Vec<String> = Vec::new();
    let mut undated = 0u32;
    for (n, row) in rows.iter().enumerate().skip(1) {
        match get(row, Some(kind)).to_lowercase().as_str() {
            "task" => {
                let indent = get(row, col("INDENT")).parse::<usize>().unwrap_or(1).max(1);
                stack.truncate(indent - 1);
                let key = format!("{name}#{n}");
                let mut task = Task {
                    key: key.clone(),
                    list: Some(name.to_string()),
                    parent: stack.last().cloned(),
                    notes: get(row, col("DESCRIPTION")),
                    ..Task::default()
                };
                // Labels live in the content as @label.
                let mut words = Vec::new();
                for word in get(row, Some(content)).split_whitespace() {
                    match word.strip_prefix('@').filter(|l| !l.is_empty()) {
                        Some(label) => task.tags.push(label.to_string()),
                        None => words.push(word.to_string()),
                    }
                }
                task.title = words.join(" ");
                // In the CSV 1 is the highest of four; 4 is "no priority".
                task.priority = match get(row, col("PRIORITY")).as_str() {
                    "1" => 3,
                    "2" => 2,
                    "3" => 1,
                    _ => 0,
                };
                let date = get(row, col("DATE"));
                if !date.is_empty() {
                    let iso = date
                        .get(..10)
                        .and_then(|d| NaiveDate::parse_from_str(d, "%Y-%m-%d").ok())
                        .map(|d| d.format("%Y-%m-%d").to_string());
                    task.due = iso.or_else(|| quickadd::parse(&date, today).due);
                    if task.due.is_none() || date.to_lowercase().contains("every") {
                        undated += 1;
                        task.notes = format!("{}\nTodoist date: {date}", task.notes).trim().to_string();
                    }
                }
                stack.push(key);
                out.tasks.push(task);
            }
            "note" => {
                if let Some(task) = out.tasks.last_mut() {
                    task.notes = format!("{}\n{}", task.notes, get(row, Some(content)))
                        .trim()
                        .to_string();
                }
            }
            // Sections have no counterpart; their tasks stay in the list.
            _ => stack.clear(),
        }
    }
    if undated > 0 {
        out.notes.push(format!("{undated} tasks had a date or a repeat written in words that was not understood; the original text was added to their notes."));
    }
    out.notes
        .push("Sections, assignees and completed tasks are not part of a Todoist export.".into());
    Ok(out)
}

// ---------------------------------------------------------------- Trello

fn iso_instant(value: &Value) -> Option<String> {
    DateTime::parse_from_rfc3339(value.as_str()?)
        .ok()
        .map(|d| local_moment(d.with_timezone(&Utc)))
}

/// A Trello board exported as JSON: lists become lists, cards tasks, checklist items subtasks.
fn parse_trello(board: &Value) -> Result<Parsed> {
    let array = |key: &str| board.get(key).and_then(Value::as_array).cloned().unwrap_or_default();
    let text = |v: &Value, key: &str| v.get(key).and_then(Value::as_str).unwrap_or_default().to_string();
    let closed = |v: &Value| v.get("closed").and_then(Value::as_bool).unwrap_or(false);
    let mut out = Parsed {
        source: "Trello",
        ..Parsed::default()
    };
    let board_name = text(board, "name");
    for list in array("lists").iter().filter(|l| !closed(l)) {
        let name = if board_name.is_empty() {
            text(list, "name")
        } else {
            format!("{board_name}: {}", text(list, "name"))
        };
        out.lists.push(List {
            key: text(list, "id"),
            name,
            color: String::new(),
        });
    }
    let labels: HashMap<String, String> = array("labels")
        .iter()
        .map(|l| {
            (
                text(l, "id"),
                if text(l, "name").is_empty() {
                    text(l, "color")
                } else {
                    text(l, "name")
                },
            )
        })
        .collect();
    let mut checklists: HashMap<String, Vec<Value>> = HashMap::new();
    for checklist in array("checklists") {
        checklists
            .entry(text(&checklist, "idCard"))
            .or_default()
            .push(checklist);
    }
    let mut archived = 0u32;
    for card in array("cards") {
        if closed(&card) || !out.lists.iter().any(|l| l.key == text(&card, "idList")) {
            archived += 1;
            continue;
        }
        let id = text(&card, "id");
        let complete = card.get("dueComplete").and_then(Value::as_bool).unwrap_or(false);
        out.tasks.push(Task {
            key: id.clone(),
            list: Some(text(&card, "idList")),
            title: text(&card, "name"),
            notes: text(&card, "desc"),
            due: card.get("due").and_then(iso_instant),
            start: card.get("start").and_then(iso_instant).map(|s| s[..10].to_string()),
            done: complete.then(|| local_moment(Utc::now())),
            tags: card
                .get("idLabels")
                .and_then(Value::as_array)
                .map(|ids| {
                    ids.iter()
                        .filter_map(|i| labels.get(i.as_str()?).cloned())
                        .filter(|l| !l.is_empty())
                        .collect()
                })
                .unwrap_or_default(),
            ..Task::default()
        });
        for checklist in checklists.remove(&id).unwrap_or_default() {
            let mut items = checklist
                .get("checkItems")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            items.sort_by(|a, b| {
                a.get("pos")
                    .and_then(Value::as_f64)
                    .partial_cmp(&b.get("pos").and_then(Value::as_f64))
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            for item in items {
                out.tasks.push(Task {
                    key: text(&item, "id"),
                    parent: Some(id.clone()),
                    title: text(&item, "name"),
                    due: item.get("due").and_then(iso_instant),
                    done: (text(&item, "state") == "complete").then(|| local_moment(Utc::now())),
                    ..Task::default()
                });
            }
        }
    }
    if archived > 0 {
        out.notes.push(format!(
            "{archived} archived cards (or cards of archived lists) were skipped."
        ));
    }
    out.notes
        .push("Comments, members, attachments and custom fields are not imported.".into());
    Ok(out)
}

// ---------------------------------------------------------------- Microsoft To Do

fn graph_moment(value: Option<&Value>, date_only: bool) -> Option<String> {
    let value = value?;
    let text = value.get("dateTime").and_then(Value::as_str)?;
    let moment = NaiveDateTime::parse_from_str(text.get(..19)?, "%Y-%m-%dT%H:%M:%S").ok()?;
    if date_only {
        return Some(moment.date().format("%Y-%m-%d").to_string());
    }
    let utc = value
        .get("timeZone")
        .and_then(Value::as_str)
        .is_none_or(|z| z.eq_ignore_ascii_case("UTC"));
    Some(if utc {
        local_moment(Utc.from_utc_datetime(&moment))
    } else {
        moment.format("%Y-%m-%dT%H:%M").to_string()
    })
}

/// Lists with their tasks as Microsoft Graph returns them: either an array
/// of `todoTaskList` objects each carrying `tasks`, or `{ "value": [...] }`.
fn parse_mstodo(root: &Value) -> Result<Parsed> {
    let lists = root
        .as_array()
        .or_else(|| root.get("value").and_then(Value::as_array))
        .ok_or_else(|| invalid("not a Microsoft To Do export"))?;
    let text = |v: &Value, key: &str| v.get(key).and_then(Value::as_str).unwrap_or_default().to_string();
    let mut out = Parsed {
        source: "Microsoft To Do",
        ..Parsed::default()
    };
    let mut odd_repeat = 0u32;
    for list in lists {
        let key = text(list, "id");
        // The export tool writes `wellKnownListName`, Graph itself `wellknownListName`.
        let well_known = list
            .get("wellknownListName")
            .or_else(|| list.get("wellKnownListName"))
            .and_then(Value::as_str)
            .unwrap_or_default();
        let default = well_known == "defaultList";
        if !default {
            out.lists.push(List {
                key: key.clone(),
                name: text(list, "displayName"),
                color: String::new(),
            });
        }
        for task in list.get("tasks").and_then(Value::as_array).cloned().unwrap_or_default() {
            let id = text(&task, "id");
            let repeat = task.get("recurrence").and_then(|r| r.get("pattern")).and_then(|p| {
                let interval = p.get("interval").and_then(Value::as_u64).unwrap_or(1) as u32;
                Some(match p.get("type").and_then(Value::as_str)? {
                    "daily" => rule(Freq::Daily, interval),
                    "weekly" => {
                        let names = [
                            "monday",
                            "tuesday",
                            "wednesday",
                            "thursday",
                            "friday",
                            "saturday",
                            "sunday",
                        ];
                        let days = p
                            .get("daysOfWeek")
                            .and_then(Value::as_array)
                            .cloned()
                            .unwrap_or_default();
                        let mut weekdays: Vec<u32> = days
                            .iter()
                            .filter_map(|d| {
                                names
                                    .iter()
                                    .position(|n| d.as_str().is_some_and(|s| s.eq_ignore_ascii_case(n)))
                            })
                            .map(|i| i as u32 + 1)
                            .collect();
                        weekdays.sort_unstable();
                        Repeat {
                            weekdays: if weekdays.len() > 1 { weekdays } else { vec![] },
                            ..rule(Freq::Weekly, interval)
                        }
                    }
                    "absoluteMonthly" => Repeat {
                        monthday: p.get("dayOfMonth").and_then(Value::as_u64).map(|d| d as u32),
                        ..rule(Freq::Monthly, interval)
                    },
                    "absoluteYearly" => rule(Freq::Yearly, interval),
                    _ => return None,
                })
            });
            if task.get("recurrence").is_some_and(|r| !r.is_null()) && repeat.is_none() {
                odd_repeat += 1;
            }
            let done = (text(&task, "status") == "completed").then(|| {
                graph_moment(task.get("completedDateTime"), false).unwrap_or_else(|| local_moment(Utc::now()))
            });
            out.tasks.push(Task {
                key: id.clone(),
                list: (!default).then(|| key.clone()),
                title: text(&task, "title"),
                notes: task
                    .get("body")
                    .map(|b| text(b, "content"))
                    .unwrap_or_default()
                    .trim()
                    .to_string(),
                due: graph_moment(task.get("dueDateTime"), true),
                start: graph_moment(task.get("startDateTime"), true),
                remind: graph_moment(task.get("reminderDateTime"), false),
                priority: match text(&task, "importance").as_str() {
                    "high" => 3,
                    "low" => 1,
                    _ => 0,
                },
                tags: task
                    .get("categories")
                    .and_then(Value::as_array)
                    .map(|c| c.iter().filter_map(|t| t.as_str().map(str::to_string)).collect())
                    .unwrap_or_default(),
                done,
                repeat,
                ..Task::default()
            });
            for item in task
                .get("checklistItems")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
            {
                out.tasks.push(Task {
                    key: format!("{id}/{}", text(&item, "id")),
                    parent: Some(id.clone()),
                    title: text(&item, "displayName"),
                    done: item
                        .get("isChecked")
                        .and_then(Value::as_bool)
                        .unwrap_or(false)
                        .then(|| local_moment(Utc::now())),
                    ..Task::default()
                });
            }
        }
    }
    if odd_repeat > 0 {
        out.notes.push(format!(
            "{odd_repeat} tasks repeat on a relative pattern (such as \"the second Tuesday\") that was not converted."
        ));
    }
    out.notes
        .push("Attachments and linked resources are not imported.".into());
    Ok(out)
}

// ---------------------------------------------------------------- writing

fn derived_id(source: &str, kind: &str, key: &str) -> String {
    Uuid::new_v5(
        &Uuid::NAMESPACE_URL,
        format!("lists-import:{source}:{kind}:{key}").as_bytes(),
    )
    .to_string()
}

fn clean_tag(tag: &str) -> String {
    tag.trim()
        .trim_start_matches('#')
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join("-")
}

impl Store {
    fn write_import(&self, parsed: Parsed) -> Result<ImportReport> {
        let source = parsed.source;
        let mut report = ImportReport {
            source: source.to_string(),
            notes: parsed.notes,
            ..ImportReport::default()
        };
        let list_id: HashMap<String, String> = parsed
            .lists
            .iter()
            .map(|l| (l.key.clone(), derived_id(source, "list", &l.key)))
            .collect();
        let task_id: HashMap<String, String> = parsed
            .tasks
            .iter()
            .map(|t| (t.key.clone(), derived_id(source, "task", &t.key)))
            .collect();
        let mut blobs: Vec<(PathBuf, String)> = Vec::new();

        self.write(|w| {
            let mut last: Option<String> =
                w.tx.query_row("SELECT max(pos) FROM lists WHERE id != 'inbox'", [], |r| r.get(0))?;
            for list in &parsed.lists {
                let id = &list_id[&list.key];
                let exists: bool = w.tx.query_row(
                    "SELECT count(*) > 0 FROM fields WHERE kind = 'list' AND id = ?1",
                    [id],
                    |r| r.get(0),
                )?;
                w.set(
                    KIND_LIST,
                    id,
                    "name",
                    json!(if list.name.trim().is_empty() {
                        "Imported"
                    } else {
                        list.name.trim()
                    }),
                )?;
                if !list.color.is_empty() {
                    w.set(KIND_LIST, id, "color", json!(list.color.to_uppercase()))?;
                }
                if !exists {
                    let pos = order::between(last.as_deref(), None);
                    w.set(KIND_LIST, id, "pos", json!(pos))?;
                    w.set(KIND_LIST, id, "deleted", json!(false))?;
                    last = Some(pos);
                }
                report.lists += 1;
            }
            // Positions follow the order in the source, per list and per parent.
            let mut cursor: BTreeMap<String, String> = BTreeMap::new();
            for task in &parsed.tasks {
                if task.title.trim().is_empty() {
                    continue;
                }
                let id = &task_id[&task.key];
                let parent = task.parent.as_ref().and_then(|p| task_id.get(p)).filter(|p| *p != id);
                let list = task
                    .list
                    .as_ref()
                    .and_then(|l| list_id.get(l))
                    .cloned()
                    .unwrap_or_else(|| INBOX_ID.to_string());
                let container = parent.cloned().unwrap_or_else(|| format!("list:{list}"));
                let pos = order::between(cursor.get(&container).map(String::as_str), None);
                cursor.insert(container, pos.clone());
                let mut set = |field: &str, value: Value| w.set(KIND_TASK, id, field, value);
                set("title", json!(task.title.trim()))?;
                set("list", json!(list))?;
                set("parent", json!(parent))?;
                set("pos", json!(pos))?;
                set("notes", json!(task.notes.trim()))?;
                set("start", json!(task.start))?;
                set("due", json!(task.due))?;
                set("remind", json!(task.remind))?;
                set("priority", json!(task.priority.clamp(0, 3)))?;
                set("done", json!(task.done))?;
                set("project", json!(task.project && parent.is_none()))?;
                set(
                    "repeat",
                    task.repeat
                        .as_ref()
                        .map(serde_json::to_value)
                        .transpose()?
                        .unwrap_or(Value::Null),
                )?;
                set("deleted", json!(false))?;
                for tag in task.tags.iter().map(|t| clean_tag(t)).filter(|t| !t.is_empty()) {
                    set(&format!("tag:{tag}"), json!(true))?;
                }
                for (index, (name, path)) in task.files.iter().enumerate() {
                    let Ok(bytes) = std::fs::read(path) else { continue };
                    let sha256 = hex(&Sha256::digest(&bytes));
                    let attachment = derived_id(source, "attachment", &format!("{}#{index}", task.key));
                    w.set(KIND_ATTACHMENT, &attachment, "task", json!(id))?;
                    w.set(KIND_ATTACHMENT, &attachment, "name", json!(name))?;
                    w.set(
                        KIND_ATTACHMENT,
                        &attachment,
                        "mime",
                        json!(crate::store::guess_mime(name)),
                    )?;
                    w.set(KIND_ATTACHMENT, &attachment, "size", json!(bytes.len()))?;
                    w.set(KIND_ATTACHMENT, &attachment, "sha256", json!(sha256))?;
                    w.set(KIND_ATTACHMENT, &attachment, "deleted", json!(false))?;
                    blobs.push((path.clone(), sha256));
                    report.attachments += 1;
                }
                report.tasks += 1;
            }
            Ok(())
        })?;
        for (path, sha256) in blobs {
            let target = self.blob_path(&sha256);
            if !target.exists() {
                let tmp = target.with_extension("part");
                std::fs::copy(&path, &tmp)?;
                std::fs::rename(&tmp, &target)?;
            }
        }
        Ok(report)
    }
}

#[uniffi::export]
impl Store {
    /// Imports a file exported from another task manager. The format is
    /// recognised from the content: a 2Do backup (`.2dodb`), a Todoist CSV
    /// template, a Trello board JSON, or Microsoft To Do lists as JSON.
    pub fn import_file(&self, path: String) -> Result<ImportReport> {
        let result = (|| {
            let path = Path::new(&path);
            let mut head = [0u8; 4];
            let read = std::fs::File::open(path)?.read(&mut head)?;
            let parsed = if read >= 2 && &head[..2] == b"PK" {
                let work = std::env::temp_dir().join(format!("lists-import-{}", Uuid::now_v7().simple()));
                std::fs::create_dir_all(&work)?;
                let parsed = parse_2do(path, &work);
                let written = parsed.and_then(|p| self.write_import(p));
                let _ = std::fs::remove_dir_all(&work);
                return written;
            } else {
                let text =
                    String::from_utf8(std::fs::read(path)?).map_err(|_| invalid("the file is not UTF-8 text"))?;
                let trimmed = text.trim_start_matches('\u{feff}').trim_start();
                if trimmed.starts_with('{') || trimmed.starts_with('[') {
                    let value: Value =
                        serde_json::from_str(trimmed).map_err(|e| invalid(format!("not valid JSON: {e}")))?;
                    if value.get("cards").is_some() && value.get("lists").is_some() {
                        parse_trello(&value)?
                    } else {
                        parse_mstodo(&value)?
                    }
                } else {
                    let name = path
                        .file_stem()
                        .map(|s| s.to_string_lossy().into_owned())
                        .unwrap_or_else(|| "Todoist".into());
                    parse_todoist(&text, &name)?
                }
            };
            self.write_import(parsed)
        })();
        self.note_result("import", &result, LogLevel::Info, |report| {
            format!(
                "{}: {} lists, {} tasks, {} attachments",
                report.source, report.lists, report.tasks, report.attachments
            )
        });
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn csv_reader_handles_quotes_and_line_breaks() {
        let rows = csv("\u{feff}a,\"b, c\",\"d \"\"e\"\"\"\r\n1,\"two\nlines\",3\n");
        assert_eq!(rows, vec![vec!["a", "b, c", "d \"e\""], vec!["1", "two\nlines", "3"]]);
    }

    #[test]
    fn twodo_dates() {
        // Noon UTC on 2026-09-27; the time of day is a number written as HHMM.
        assert_eq!(twodo_date(1_790_510_400.0, 999_999.0).as_deref(), Some("2026-09-27"));
        assert_eq!(twodo_date(1_790_510_400.0, 930.0).as_deref(), Some("2026-09-27T09:30"));
        assert_eq!(twodo_date(1_790_510_400.0, 1405.0).as_deref(), Some("2026-09-27T14:05"));
        assert_eq!(twodo_date(1_790_510_400.0, 30.0).as_deref(), Some("2026-09-27T00:30"));
        assert_eq!(twodo_date(1_790_510_400.0, 2359.0).as_deref(), Some("2026-09-27T23:59"));
        assert_eq!(
            twodo_date(1_790_510_400.0, 1299.0).as_deref(),
            Some("2026-09-27"),
            "99 minutes is not a time"
        );
        assert_eq!(twodo_date(6_406_192_800.0, 999_999.0), None);
        assert_eq!(twodo_date(0.0, 999_999.0), None);
        // Start dates as 2Do wrote them for 2026-12-05 and for 2026-12-05 08:15.
        assert_eq!(twodo_start(1_796_428_800.0).as_deref(), Some("2026-12-05"));
        assert_eq!(twodo_start(1_796_458_500.0).as_deref(), Some("2026-12-05T08:15"));
        assert_eq!(twodo_start(6_406_192_800.0), None);
    }

    /// Codes exactly as 2Do 4.19 stored them for tasks created with these rules.
    #[test]
    fn twodo_repeat_codes() {
        let none = (0, 0, 0.0);
        let monday = NaiveDate::from_ymd_opt(2026, 12, 7);
        let get = |kind, value| twodo_repeat(kind, value, 1, none, monday).unwrap();
        let unit = |kind, value| (get(kind, value).freq, get(kind, value).interval);
        assert_eq!(unit(256, 1), (Freq::Daily, 1));
        assert_eq!(unit(257, 1), (Freq::Weekly, 1));
        assert_eq!(unit(257, 2), (Freq::Weekly, 2));
        assert_eq!(unit(258, 1), (Freq::Monthly, 1));
        assert_eq!(unit(258, 3), (Freq::Monthly, 3));
        assert_eq!(unit(259, 1), (Freq::Yearly, 1));
        assert_eq!(unit(259, 3), (Freq::Yearly, 3));

        let days = |kind| get(kind, 1).weekdays;
        assert_eq!(
            days(64),
            Vec::<u32>::new(),
            "Monday on a task due on a Monday is the plain weekly rule"
        );
        assert_eq!(days(1), [7]);
        assert_eq!(days(32), [2]);
        assert_eq!(days(2), [6]);
        assert_eq!(days(84), [1, 3, 5]);
        assert_eq!(days(124), [1, 2, 3, 4, 5]);
        assert_eq!(get(84, 1).freq, Freq::Weekly);

        let nth = |kind, value| {
            (
                get(kind, value).nth.unwrap(),
                get(kind, value).nth_weekday.unwrap(),
                get(kind, value).freq,
            )
        };
        assert_eq!(nth(260, 1), (1, 1, Freq::Monthly), "first Monday");
        assert_eq!(nth(261, 2), (2, 2, Freq::Monthly), "second Tuesday");
        assert_eq!(nth(262, 3), (3, 3, Freq::Monthly), "third Wednesday");
        assert_eq!(nth(263, 4), (4, 4, Freq::Monthly), "fourth Thursday");
        assert_eq!(nth(264, 6), (-1, 5, Freq::Monthly), "last Friday");
        assert_eq!(nth(265, 5), (5, 6, Freq::Monthly), "fifth Saturday");
        assert_eq!(nth(266, 1), (1, 7, Freq::Monthly), "first Sunday");
        assert_eq!(nth(260, 6), (-1, 1, Freq::Monthly), "last Monday");

        assert!(twodo_repeat(256, 1, 2, none, monday).unwrap().from_done);
        assert!(twodo_repeat(2, 1, 2, none, monday).unwrap().from_done);
        assert_eq!(twodo_repeat(256, 1, 1, (2, 5, 0.0), monday).unwrap().count, Some(5));
        assert_eq!(
            twodo_repeat(256, 1, 1, (1, 0, 1_800_014_400.0), monday)
                .unwrap()
                .until
                .as_deref(),
            Some("2027-01-15")
        );

        for (kind, value) in [(128, 1), (255, 1), (256, 0), (260, 7), (267, 1), (512, 1)] {
            assert!(twodo_repeat(kind, value, 1, none, monday).is_none(), "{kind}/{value}");
        }
    }
}
