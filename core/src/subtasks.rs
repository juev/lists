//! R10, R112, S42: a subtask is a line with a mark and a title. Data that says
//! otherwise, whatever it came from, is brought to that with ordinary stamped
//! writes, so that the other devices get the same.

use rusqlite::{params, Connection};
use serde_json::{json, Value};

use crate::db::{self, Change, Touched, KIND_ATTACHMENT, KIND_TASK};
use crate::error::Result;
use crate::order;

/// Whether the task is a subtask: it has a parent, and the parent is not a project.
/// A project is a task of the top level with the mark of a project; its children are full tasks (R30).
pub(crate) fn is_subtask(conn: &Connection, id: &str) -> Result<bool> {
    Ok(conn.query_row(
        "SELECT EXISTS (SELECT 1 FROM tasks t JOIN tasks p ON p.id = t.eff_parent
         WHERE t.id = ?1 AND NOT (p.project = 1 AND p.eff_parent IS NULL))",
        [id],
        |r| r.get(0),
    )?)
}

/// Whether the task is a project.
pub(crate) fn is_project(conn: &Connection, id: &str) -> Result<bool> {
    Ok(conn.query_row(
        "SELECT EXISTS (SELECT 1 FROM tasks WHERE id = ?1 AND project = 1 AND eff_parent IS NULL)",
        [id],
        |r| r.get(0),
    )?)
}

/// Brings the data to R10. `stamp` gives the stamp of the next write.
/// The records of completed occurrences are history and are left as they are.
pub(crate) fn tidy(conn: &Connection, stamp: &mut dyn FnMut() -> String) -> Result<()> {
    // A chain is one level shorter after each pass.
    while raise(conn, stamp)? {}
    clear(conn, stamp)
}

fn write(
    conn: &Connection,
    stamp: &mut dyn FnMut() -> String,
    touched: &mut Touched,
    kind: &str,
    id: &str,
    field: &str,
    value: Value,
) -> Result<()> {
    let change = Change {
        kind: kind.into(),
        id: id.into(),
        field: field.into(),
        value,
        stamp: stamp(),
    };
    db::apply(conn, &change, true, touched)?;
    Ok(())
}

/// A subtask of a subtask becomes a subtask of the task its parent lies under, right after that parent.
fn raise(conn: &Connection, stamp: &mut dyn FnMut() -> String) -> Result<bool> {
    // (task, its parent, the task above the parent), in the order they are shown. One level at a time,
    // from the top: a chain a → b → c then becomes a, b, c and not a, c, b.
    let nested: Vec<(String, String, String)> = {
        let mut stmt = conn.prepare_cached(
            "SELECT t.id, p.id, g.id FROM tasks t
             JOIN tasks p ON p.id = t.eff_parent
             JOIN tasks g ON g.id = p.eff_parent
             WHERE t.log_of IS NULL AND NOT (g.project = 1 AND g.eff_parent IS NULL)
               AND (g.eff_parent IS NULL OR EXISTS (
                    SELECT 1 FROM tasks x WHERE x.id = g.eff_parent AND x.project = 1 AND x.eff_parent IS NULL))
             ORDER BY g.id, p.pos, p.id, t.pos, t.id",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    if nested.is_empty() {
        return Ok(false);
    }
    let mut touched = Touched::new();
    let mut above = String::new();
    let mut siblings: Vec<(String, String)> = Vec::new();
    // The one the next raised task goes after: the former parent, then the task raised before it.
    let mut anchor = String::new();
    let mut parent = String::new();
    for (id, former, top) in nested {
        if top != above {
            let mut stmt = conn.prepare_cached("SELECT id, pos FROM tasks WHERE eff_parent = ?1 ORDER BY pos, id")?;
            let rows = stmt.query_map([&top], |r| Ok((r.get(0)?, r.get(1)?)))?;
            siblings = rows.collect::<rusqlite::Result<_>>()?;
            above = top.clone();
            parent.clear();
        }
        if former != parent {
            parent = former.clone();
            anchor = former;
        }
        let at = siblings.iter().position(|(sibling, _)| *sibling == anchor);
        let lo = at.map(|i| siblings[i].1.as_str());
        let hi = at.and_then(|i| siblings.get(i + 1)).map(|s| s.1.as_str());
        let pos = order::between(lo, hi);
        write(conn, stamp, &mut touched, KIND_TASK, &id, "parent", json!(top))?;
        write(conn, stamp, &mut touched, KIND_TASK, &id, "pos", json!(pos))?;
        siblings.insert(at.map_or(siblings.len(), |i| i + 1), (id.clone(), pos));
        anchor = id;
    }
    db::settle(conn, &touched)?;
    Ok(true)
}

/// A subtask keeps its title and its state; the other fields and the attachments are removed.
fn clear(conn: &Connection, stamp: &mut dyn FnMut() -> String) -> Result<()> {
    type Row = (String, bool, bool, bool, bool, bool, bool);
    let subtasks: Vec<Row> = {
        let mut stmt = conn.prepare_cached(
            "SELECT t.id, t.notes <> '', t.start IS NOT NULL, t.due IS NOT NULL, t.priority <> 0,
                    t.repeat IS NOT NULL, t.remind IS NOT NULL
             FROM tasks t JOIN tasks p ON p.id = t.eff_parent
             WHERE t.log_of IS NULL AND NOT (p.project = 1 AND p.eff_parent IS NULL)
               AND (t.notes <> '' OR t.start IS NOT NULL OR t.due IS NOT NULL OR t.priority <> 0
                    OR t.repeat IS NOT NULL OR t.remind IS NOT NULL
                    OR EXISTS (SELECT 1 FROM task_tags g WHERE g.task_id = t.id)
                    OR EXISTS (SELECT 1 FROM attachments a WHERE a.task_id = t.id AND a.deleted = 0))
             ORDER BY t.id",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
                r.get(6)?,
            ))
        })?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    if subtasks.is_empty() {
        return Ok(());
    }
    let mut touched = Touched::new();
    for (id, notes, start, due, priority, repeat, remind) in subtasks {
        let fields = [
            ("notes", notes),
            ("start", start),
            ("due", due),
            ("priority", priority),
            ("repeat", repeat),
            ("remind", remind),
        ];
        for (field, set) in fields {
            if set {
                write(conn, stamp, &mut touched, KIND_TASK, &id, field, Value::Null)?;
            }
        }
        let tags: Vec<String> = {
            let mut stmt = conn.prepare_cached("SELECT tag FROM task_tags WHERE task_id = ?1 ORDER BY tag")?;
            let rows = stmt.query_map([&id], |r| r.get(0))?;
            rows.collect::<rusqlite::Result<_>>()?
        };
        for tag in tags {
            write(
                conn,
                stamp,
                &mut touched,
                KIND_TASK,
                &id,
                &format!("tag:{tag}"),
                json!(false),
            )?;
        }
        let files: Vec<String> = {
            let mut stmt =
                conn.prepare_cached("SELECT id FROM attachments WHERE task_id = ?1 AND deleted = 0 ORDER BY id")?;
            let rows = stmt.query_map(params![id], |r| r.get(0))?;
            rows.collect::<rusqlite::Result<_>>()?
        };
        for file in files {
            write(
                conn,
                stamp,
                &mut touched,
                KIND_ATTACHMENT,
                &file,
                "deleted",
                json!(true),
            )?;
        }
    }
    db::settle(conn, &touched)
}
