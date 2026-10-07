//! Merge and sync rules: docs/specs/sync.md. Storage is a temporary folder.

mod common;

use std::path::Path;

use common::*;
use lists_core::sync::remote::DirRemote;
use lists_core::*;
use tempfile::TempDir;

fn sync(d: &Device, storage: &TempDir) -> SyncReport {
    d.sync_with(&DirRemote::new(storage.path())).unwrap()
}

/// Both devices see everything the other has written.
fn settle(a: &Device, b: &Device, storage: &TempDir) {
    sync(a, storage);
    sync(b, storage);
    sync(a, storage);
}

fn files(storage: &TempDir, dir: &str) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(storage.path().join("lists/v1").join(dir))
        .map(|entries| {
            entries
                .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

/// Everything a user can see, in a form two devices can compare.
fn dump(d: &Device) -> Vec<String> {
    fn walk(d: &Device, tasks: Vec<TaskItem>, depth: usize, out: &mut Vec<String>) {
        for t in tasks {
            out.push(format!(
                "{}{} | {} | due={:?} start={:?} prio={:?} done={} tags={:?} repeat={} notes={:?} files={}",
                "  ".repeat(depth),
                t.id,
                t.title,
                t.due,
                t.start,
                t.priority,
                t.done.is_some(),
                t.tags,
                t.repeat.is_some(),
                t.notes,
                t.attachments
            ));
            walk(d, d.subtasks(t.id).unwrap(), depth + 1, out);
        }
    }
    let mut out = Vec::new();
    for list in d.lists().unwrap() {
        out.push(format!(
            "# {} | {} | {} | {:?} | {}",
            list.id, list.name, list.color, list.sort, list.archived
        ));
        walk(d, d.tasks(Scope::List { id: list.id }).unwrap(), 1, &mut out);
    }
    out.push("# trash".into());
    out.extend(
        d.tasks(Scope::Trash)
            .unwrap()
            .into_iter()
            .map(|t| format!("  {} | {}", t.id, t.title)),
    );
    out.push("# completed".into());
    out.extend(
        d.tasks(Scope::Completed)
            .unwrap()
            .into_iter()
            .map(|t| format!("  {} | {} | log={}", t.id, t.title, t.is_log)),
    );
    out
}

#[test]
fn s2_edits_of_different_fields_are_both_kept() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    let t = add(&a, "исходное");
    settle(&a, &b, &storage);
    assert_eq!(b.task(t.id.clone()).unwrap().title, "исходное");

    a.set_title(t.id.clone(), "новое название".into()).unwrap();
    b.set_due(t.id.clone(), Some("2026-10-09".into())).unwrap();
    settle(&a, &b, &storage);

    for d in [&a, &b] {
        let got = d.task(t.id.clone()).unwrap();
        assert_eq!(got.title, "новое название");
        assert_eq!(got.due.as_deref(), Some("2026-10-09"));
    }
}

#[test]
fn s2_same_field_later_write_wins_and_resync_is_a_no_op() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    let t = add(&a, "исходное");
    settle(&a, &b, &storage);

    a.set_title(t.id.clone(), "от A".into()).unwrap();
    b.set_now_for_tests("2026-10-05T10:05");
    b.set_title(t.id.clone(), "от B, позже".into()).unwrap();
    // Order of delivery must not matter: A, the loser, syncs last here.
    sync(&b, &storage);
    sync(&a, &storage);
    sync(&b, &storage);

    assert_eq!(a.task(t.id.clone()).unwrap().title, "от B, позже");
    assert_eq!(b.task(t.id).unwrap().title, "от B, позже");
    assert_eq!(sync(&a, &storage), SyncReport::default());
    assert_eq!(sync(&b, &storage), SyncReport::default());
}

#[test]
fn s1_edit_made_after_seeing_a_future_stamp_still_wins() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    // B's clock runs a day ahead.
    b.set_now_for_tests("2026-10-06T10:00");
    let t = add(&b, "из будущего");
    settle(&b, &a, &storage);

    a.set_title(t.id.clone(), "исправлено на A".into()).unwrap();
    settle(&a, &b, &storage);
    assert_eq!(b.task(t.id).unwrap().title, "исправлено на A");
}

#[test]
fn s3_delete_and_concurrent_edit() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    let t = add(&a, "задача");
    settle(&a, &b, &storage);

    a.delete_task(t.id.clone()).unwrap();
    b.set_notes(t.id.clone(), "заметка от B".into()).unwrap();
    settle(&a, &b, &storage);
    for d in [&a, &b] {
        assert!(view(d, Scope::Inbox).is_empty());
        assert_eq!(view(d, Scope::Trash), ["задача"]);
    }

    a.restore_task(t.id.clone()).unwrap();
    settle(&a, &b, &storage);
    assert_eq!(b.task(t.id).unwrap().notes, "заметка от B");
    assert_eq!(view(&b, Scope::Inbox), ["задача"]);
}

#[test]
fn s4_concurrent_inserts_end_up_in_the_same_order() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    add(&a, "первая");
    settle(&a, &b, &storage);
    // Both append "at the end": the keys collide and the id breaks the tie.
    add(&a, "от A");
    add(&b, "от B");
    settle(&a, &b, &storage);
    assert_eq!(view(&a, Scope::Inbox).len(), 3);
    assert_eq!(view(&a, Scope::Inbox), view(&b, Scope::Inbox));
}

#[test]
fn s5_concurrent_moves_into_each_other_do_not_leave_a_cycle() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    let x = add(&a, "X");
    let y = add(&a, "Y");
    settle(&a, &b, &storage);

    a.move_task(x.id.clone(), None, Some(y.id.clone()), None).unwrap();
    b.set_now_for_tests("2026-10-05T10:05");
    b.move_task(y.id.clone(), None, Some(x.id.clone()), None).unwrap();
    settle(&a, &b, &storage);

    // B's move is the later one, so it is the one undone: Y stays on top, X under it.
    for d in [&a, &b] {
        assert_eq!(view(d, Scope::Inbox), ["Y"]);
        assert_eq!(titles(&d.subtasks(y.id.clone()).unwrap()), ["X"]);
        assert!(d.subtasks(x.id.clone()).unwrap().is_empty());
    }
    // The tree can be edited again afterwards.
    a.move_task(x.id.clone(), None, None, None).unwrap();
    settle(&a, &b, &storage);
    assert_eq!(view(&b, Scope::Inbox), ["X", "Y"]);
}

#[test]
fn s6_task_added_to_a_list_deleted_elsewhere_lands_in_the_inbox() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    let list = a.create_list("Временный".into()).unwrap();
    settle(&a, &b, &storage);

    a.delete_list(list.id.clone()).unwrap();
    b.create_task(NewTask {
        title: "поздняя".into(),
        list_id: Some(list.id),
        ..NewTask::default()
    })
    .unwrap();
    settle(&a, &b, &storage);
    for d in [&a, &b] {
        assert_eq!(view(d, Scope::Inbox), ["поздняя"]);
        assert_eq!(d.lists().unwrap().len(), 1);
    }
}

#[test]
fn s7_same_occurrence_completed_on_two_devices_is_recorded_once() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    let t = add(&a, "зарядка");
    a.set_due(t.id.clone(), Some("2026-10-05".into())).unwrap();
    a.set_repeat(
        t.id.clone(),
        Some(Repeat {
            freq: Freq::Daily,
            interval: 1,
            weekdays: vec![],
            monthday: None,
            nth: None,
            nth_weekday: None,
            from_done: false,
            count: None,
            until: None,
        }),
    )
    .unwrap();
    settle(&a, &b, &storage);

    a.complete_task(t.id.clone()).unwrap();
    b.set_now_for_tests("2026-10-05T21:00");
    b.complete_task(t.id.clone()).unwrap();
    settle(&a, &b, &storage);

    for d in [&a, &b] {
        assert_eq!(view(d, Scope::Completed), ["зарядка"], "one record, not two");
        let got = d.task(t.id.clone()).unwrap();
        assert_eq!(got.due.as_deref(), Some("2026-10-06"), "moved forward once, not twice");
        assert!(got.done.is_none());
    }
}

#[test]
fn s25_clearing_completed_reaches_the_other_device_and_outlives_a_reopen() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    let mut ids = Vec::new();
    for (day, title) in [
        ("2026-08-01", "давняя"),
        ("2026-09-20", "сентябрьская"),
        ("2026-10-05", "свежая"),
    ] {
        a.set_now_for_tests(&format!("{day}T09:00"));
        let t = add(&a, title);
        a.complete_task(t.id.clone()).unwrap();
        ids.push(t.id);
    }
    // Past the time a completed task stays among the open ones (R68).
    a.set_now_for_tests(NOW);
    settle(&a, &b, &storage);
    assert_eq!(view(&b, Scope::Completed), ["свежая", "сентябрьская", "давняя"]);

    assert_eq!(a.clear_completed(Some("2026-09-05".into())).unwrap(), 1);
    b.reopen_task(ids[0].clone()).unwrap();
    settle(&a, &b, &storage);
    for d in [&a, &b] {
        assert_eq!(view(d, Scope::Completed), ["свежая", "сентябрьская"]);
        assert!(
            view(d, Scope::Inbox).is_empty(),
            "a reopen made without knowing does not bring it back"
        );
        assert!(view(d, Scope::Trash).is_empty());
    }
    assert_eq!(dump(&a), dump(&b));
}

#[test]
fn s8_truncated_log_file_is_retried_not_skipped() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    add(&a, "первая");
    add(&a, "вторая");
    sync(&a, &storage);

    let name = files(&storage, "log").pop().unwrap();
    let path = storage.path().join("lists/v1/log").join(&name);
    let whole = std::fs::read(&path).unwrap();
    std::fs::write(&path, &whole[..whole.len() * 2 / 3]).unwrap();

    assert_eq!(sync(&b, &storage).pulled, 0);
    assert!(
        view(&b, Scope::Inbox).is_empty(),
        "nothing from a half-written file is applied"
    );

    std::fs::write(&path, &whole).unwrap();
    assert!(sync(&b, &storage).pulled > 0);
    assert_eq!(view(&b, Scope::Inbox), ["первая", "вторая"]);
}

#[test]
fn s9_upload_interrupted_before_confirmation_is_repeated_identically() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    add(&a, "задача");
    sync(&a, &storage);
    let name = files(&storage, "log").pop().unwrap();
    let path = storage.path().join("lists/v1/log").join(&name);
    let first = std::fs::read(&path).unwrap();

    // Nothing new locally: a second run must not rewrite or renumber anything.
    sync(&a, &storage);
    assert_eq!(files(&storage, "log"), [name]);
    assert_eq!(std::fs::read(&path).unwrap(), first);
    sync(&b, &storage);
    assert_eq!(view(&b, Scope::Inbox), ["задача"]);
}

#[test]
fn s10_s11_compaction_keeps_late_and_new_devices_complete() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b, c) = (device(), device(), device());
    a.set_compact_after_for_tests(3);

    add(&a, "t1");
    sync(&a, &storage);
    sync(&b, &storage); // B has read A's first file and then falls behind.
    assert_eq!(view(&b, Scope::Inbox), ["t1"]);
    let from_b = add(&b, "от B");
    sync(&b, &storage);

    for i in 2..=6 {
        add(&a, &format!("t{i}"));
        sync(&a, &storage);
    }
    let a_id = a.device_id();
    let a_logs: Vec<String> = files(&storage, "log")
        .into_iter()
        .filter(|f| f.starts_with(&a_id) && f.ends_with(".jsonl"))
        .collect();
    assert!(a_logs.len() <= 3, "old log files are removed: {a_logs:?}");
    assert_eq!(
        files(&storage, "snap").iter().filter(|f| f.starts_with(&a_id)).count(),
        1
    );

    // B catches up through the snapshot; C starts from nothing.
    sync(&b, &storage);
    sync(&c, &storage);
    for d in [&b, &c] {
        let mut got = view(d, Scope::Inbox);
        got.sort();
        assert_eq!(got, ["t1", "t2", "t3", "t4", "t5", "t6", "от B"]);
    }
    // The snapshot told C which of B's files it already contains, and edits keep flowing.
    b.set_title(from_b.id.clone(), "от B, изменено".into()).unwrap();
    sync(&b, &storage);
    sync(&c, &storage);
    sync(&a, &storage);
    assert_eq!(c.task(from_b.id.clone()).unwrap().title, "от B, изменено");
    assert_eq!(a.task(from_b.id).unwrap().title, "от B, изменено");
}

#[test]
fn s11_device_whose_logs_are_all_compacted_is_still_readable() {
    let storage = tempfile::tempdir().unwrap();
    let (a, c) = (device(), device());
    a.set_compact_after_for_tests(0);
    add(&a, "единственная");
    sync(&a, &storage);
    // Everything of A is in its snapshot; what is left in the log is the mark that says so.
    let left = files(&storage, "log");
    assert!(matches!(&left[..], [mark] if mark.ends_with(".snap")), "{left:?}");

    sync(&c, &storage);
    assert_eq!(view(&c, Scope::Inbox), ["единственная"]);
}

#[test]
fn s12_joining_a_used_storage_merges_instead_of_replacing() {
    let storage = tempfile::tempdir().unwrap();
    let (a, c) = (device(), device());
    add(&a, "с A");
    sync(&a, &storage);
    add(&c, "с C");
    settle(&c, &a, &storage);
    for d in [&a, &c] {
        let mut got = view(d, Scope::Inbox);
        got.sort();
        assert_eq!(got, ["с A", "с C"]);
    }
}

#[test]
fn s13_attachment_content_follows_the_record() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    let t = add(&a, "с фото");
    let src = tempfile::tempdir().unwrap();
    let file = src.path().join("photo.png");
    std::fs::write(&file, b"\x89PNG not really").unwrap();
    let att = a
        .add_attachment(t.id.clone(), file.to_string_lossy().into_owned(), None)
        .unwrap();

    let up = sync(&a, &storage);
    assert_eq!(up.blobs_uploaded, 1);
    assert!(Path::new(
        &storage
            .path()
            .join("lists/v1/blobs")
            .join(&att.sha256[..2])
            .join(&att.sha256)
    )
    .exists());

    let down = sync(&b, &storage);
    assert_eq!(down.blobs_downloaded, 1);
    let got = b.attachments(t.id).unwrap();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].sha256, att.sha256);
    assert_eq!(
        std::fs::read(got[0].local_path.as_ref().unwrap()).unwrap(),
        b"\x89PNG not really"
    );

    // Nothing is transferred twice.
    assert_eq!(sync(&a, &storage), SyncReport::default());
    assert_eq!(sync(&b, &storage), SyncReport::default());
}

#[test]
fn s13_corrupted_attachment_content_is_not_stored() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    let t = add(&a, "с файлом");
    let src = tempfile::tempdir().unwrap();
    let file = src.path().join("a.txt");
    std::fs::write(&file, b"original").unwrap();
    let att = a
        .add_attachment(t.id.clone(), file.to_string_lossy().into_owned(), None)
        .unwrap();
    sync(&a, &storage);
    std::fs::write(
        storage
            .path()
            .join("lists/v1/blobs")
            .join(&att.sha256[..2])
            .join(&att.sha256),
        b"tampered",
    )
    .unwrap();

    assert_eq!(sync(&b, &storage).blobs_downloaded, 0);
    assert_eq!(b.attachments(t.id).unwrap()[0].local_path, None);
}

#[test]
fn s14_newer_storage_format_stops_sync_but_not_local_work() {
    let storage = tempfile::tempdir().unwrap();
    let a = device();
    std::fs::create_dir_all(storage.path().join("lists/v1")).unwrap();
    std::fs::write(
        storage.path().join("lists/v1/vault.json"),
        br#"{"format":2,"vault":"x"}"#,
    )
    .unwrap();

    let err = a.sync_with(&DirRemote::new(storage.path())).unwrap_err();
    assert!(err.to_string().contains("format 2"), "{err}");
    add(&a, "локально");
    assert_eq!(view(&a, Scope::Inbox), ["локально"]);
}

#[test]
fn s14_format_raised_while_the_app_runs_is_noticed_at_the_first_unreadable_file() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    add(&a, "t1");
    settle(&a, &b, &storage);

    // Another device moved the storage on and wrote a file this version cannot read.
    let root = storage.path().join("lists/v1");
    std::fs::write(root.join("vault.json"), br#"{"format":2,"vault":"x"}"#).unwrap();
    let next = format!("{}-{:010}.jsonl", a.device_id(), 2);
    std::fs::write(
        root.join("log").join(next),
        format!("{{\"v\":2,\"device\":\"{}\",\"seq\":2,\"count\":0}}\n", a.device_id()),
    )
    .unwrap();
    let err = b.sync_with(&DirRemote::new(storage.path())).unwrap_err();
    assert!(err.to_string().contains("format 2"), "{err}");
}

#[test]
fn s16_configured_sync_reports_status_and_keeps_changes_after_a_failure() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    assert_eq!(
        a.sync_now().unwrap(),
        SyncReport::default(),
        "no storage configured: nothing to do"
    );
    assert!(!a.sync_status().unwrap().configured);

    // A path that cannot be a directory: every write fails.
    let blocker = storage.path().join("file");
    std::fs::write(&blocker, b"x").unwrap();
    a.set_sync_config(SyncConfig::Folder {
        path: blocker.join("sub").to_string_lossy().into_owned(),
    })
    .unwrap();
    add(&a, "не потеряется");
    assert!(a.sync_now().is_err());
    let status = a.sync_status().unwrap();
    assert!(status.configured && status.pending > 0 && status.last_error.is_some() && status.last_ok.is_none());

    let good = SyncConfig::Folder {
        path: storage.path().join("ok").to_string_lossy().into_owned(),
    };
    a.set_sync_config(good.clone()).unwrap();
    assert_eq!(a.sync_config().unwrap(), good);
    assert!(a.sync_now().unwrap().pushed > 0);
    let status = a.sync_status().unwrap();
    assert_eq!((status.pending, status.last_error), (0, None));
    assert_eq!(status.last_ok.as_deref(), Some(NOW));

    b.set_sync_config(good).unwrap();
    b.sync_now().unwrap();
    assert_eq!(view(&b, Scope::Inbox), ["не потеряется"]);
}

#[test]
fn s15_a_file_brought_into_the_sync_folder_is_noticed_once() {
    let storage = tempfile::tempdir().unwrap();
    let folder = SyncConfig::Folder {
        path: storage.path().to_string_lossy().into_owned(),
    };
    let (a, b) = (device(), device());
    a.set_sync_config(folder.clone()).unwrap();
    b.set_sync_config(folder).unwrap();
    add(&a, "от A");
    a.sync_now().unwrap();
    assert!(!a.folder_changed(), "its own file is not news");

    assert!(b.folder_changed(), "A's file is there");
    assert!(!b.folder_changed(), "and is reported once");
    b.sync_now().unwrap();
    assert!(!b.folder_changed());
    // B's first run there published its snapshot and the mark for it.
    assert!(a.folder_changed());
    a.sync_now().unwrap();
    assert!(!a.folder_changed());
    assert!(!b.folder_changed(), "A had nothing to write");

    add(&b, "от B");
    b.sync_now().unwrap();
    assert!(a.folder_changed());

    // Other kinds of sync are not watched.
    assert!(!device().folder_changed());
}

#[test]
fn switching_storage_publishes_the_whole_state_there() {
    let (old, new) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let folder = |d: &TempDir| SyncConfig::Folder {
        path: d.path().to_string_lossy().into_owned(),
    };
    let (a, b, c) = (device(), device(), device());
    a.set_sync_config(folder(&old)).unwrap();
    b.set_sync_config(folder(&old)).unwrap();
    add(&a, "от A");
    a.sync_now().unwrap();
    add(&b, "от B");
    b.sync_now().unwrap();
    a.sync_now().unwrap();

    // A moves to a new storage: it must carry B's task along, not only its own writes.
    a.set_sync_config(folder(&new)).unwrap();
    a.sync_now().unwrap();
    c.set_sync_config(folder(&new)).unwrap();
    c.sync_now().unwrap();
    let mut got = view(&c, Scope::Inbox);
    got.sort();
    assert_eq!(got, ["от A", "от B"]);

    // Going back to the old storage keeps working for devices that stayed there.
    add(&a, "после возврата");
    a.set_sync_config(folder(&old)).unwrap();
    a.sync_now().unwrap();
    b.sync_now().unwrap();
    assert!(view(&b, Scope::Inbox).contains(&"после возврата".to_string()));
}

/// Three devices make random edits and sync in random order; once everyone has
/// synced twice with no edits in between, all three must show the same data.
#[test]
fn devices_converge_whatever_the_order_of_edits_and_syncs() {
    for seed in 1..=8u64 {
        let storage = tempfile::tempdir().unwrap();
        let devices = [device(), device(), device()];
        devices[1].set_compact_after_for_tests(4);
        let mut state = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15);
        let mut rnd = |n: usize| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            (state % n as u64) as usize
        };
        let mut ids: Vec<String> = Vec::new();
        let mut minute = 0;
        for step in 0..160 {
            let d = &devices[rnd(3)];
            minute += 1;
            d.set_now_for_tests(&format!("2026-10-05T{:02}:{:02}", 10 + minute / 60, minute % 60));
            let known = |d: &Device, id: &String| d.task(id.clone()).is_ok();
            let pick = if ids.is_empty() {
                None
            } else {
                Some(ids[rnd(ids.len())].clone())
            };
            match (rnd(12), pick) {
                (0..=2, _) | (_, None) => ids.push(add(d, &format!("task {step}")).id),
                (3, Some(id)) if known(d, &id) => d.set_title(id, format!("renamed {step}")).unwrap(),
                (4, Some(id)) if known(d, &id) => d.set_due(id, Some(format!("2026-10-{:02}", 1 + rnd(28)))).unwrap(),
                (5, Some(id)) if known(d, &id) => d.set_priority(id, Priority::from_i64(rnd(4) as i64)).unwrap(),
                (6, Some(id)) if known(d, &id) => drop(d.complete_task(id).unwrap()),
                (7, Some(id)) if known(d, &id) => d.delete_task(id).unwrap(),
                (8, Some(id)) if known(d, &id) => d.add_tag(id, format!("t{}", rnd(3))).unwrap(),
                (9, Some(id)) if known(d, &id) => {
                    let other = ids[rnd(ids.len())].clone();
                    if known(d, &other) {
                        // Rejected when it would create a cycle locally; that is fine.
                        d.move_task(id, None, Some(other), None).ok();
                    }
                }
                (10, Some(id)) if known(d, &id) => d.move_task(id, None, None, None).unwrap(),
                _ => drop(sync(d, &storage)),
            }
        }
        for _ in 0..2 {
            for d in &devices {
                sync(d, &storage);
            }
        }
        // What a view shows depends on the clock (R68): compare the devices at one and the same moment.
        for d in &devices {
            d.set_now_for_tests("2026-10-06T10:00");
        }
        let reference = dump(&devices[0]);
        assert!(reference.len() > 5, "seed {seed}: the run produced data");
        for (i, d) in devices.iter().enumerate().skip(1) {
            assert_eq!(dump(d), reference, "seed {seed}: device {i} differs");
        }
        for d in &devices {
            assert_eq!(sync(d, &storage).pulled, 0, "seed {seed}: nothing left to pull");
        }
    }
}

#[test]
fn s13_attachment_hash_from_the_storage_never_becomes_a_path() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    let t = add(&a, "с файлом");
    let src = tempfile::tempdir().unwrap();
    let file = src.path().join("a.txt");
    std::fs::write(&file, b"content").unwrap();
    let att = a
        .add_attachment(t.id.clone(), file.to_string_lossy().into_owned(), None)
        .unwrap();
    sync(&a, &storage);

    // A file that exists on B outside its blob folder, and a log in the storage
    // that points the attachment at it.
    let outside = b.data_dir().join("lists.sqlite");
    assert!(outside.exists());
    let log = storage.path().join("lists/v1/log");
    let snap = storage.path().join("lists/v1/snap");
    for dir in [log, snap] {
        for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
            let text = std::fs::read_to_string(entry.path()).unwrap();
            std::fs::write(entry.path(), text.replace(&att.sha256, "../lists.sqlite")).unwrap();
        }
    }

    sync(&b, &storage);
    let got = b.attachments(t.id).unwrap();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].sha256, "", "a value that is not a hash is dropped");
    assert_eq!(got[0].local_path, None);
}

#[test]
fn projects_and_saved_filters_sync_like_everything_else() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    let p = add(&a, "проект");
    a.set_project(p.id.clone(), true).unwrap();
    a.quick_add_under("шаг".into(), p.id.clone()).unwrap();
    let f = a
        .create_filter(
            "Неделя".into(),
            FilterSpec {
                due: DueWindow::Next { days: 7 },
                ..FilterSpec::default()
            },
        )
        .unwrap();
    settle(&a, &b, &storage);

    assert_eq!(titles(&b.projects().unwrap()), ["проект"]);
    assert_eq!(view(&b, Scope::Project { id: p.id }), ["шаг"]);
    assert_eq!(b.filters().unwrap()[0].spec.due, DueWindow::Next { days: 7 });

    // A rename on one device and a new condition on the other are both kept.
    a.update_filter(f.id.clone(), "Ближайшее".into(), f.spec.clone())
        .unwrap();
    b.set_now_for_tests("2026-10-05T10:05");
    b.update_filter(
        f.id.clone(),
        "Неделя".into(),
        FilterSpec {
            due: DueWindow::Next { days: 7 },
            min_priority: Priority::High,
            ..FilterSpec::default()
        },
    )
    .unwrap();
    settle(&a, &b, &storage);
    for d in [&a, &b] {
        let got = &d.filters().unwrap()[0];
        assert_eq!(
            (got.name.as_str(), got.spec.min_priority),
            ("Ближайшее", Priority::High)
        );
    }
    b.delete_filter(f.id).unwrap();
    settle(&b, &a, &storage);
    assert!(a.filters().unwrap().is_empty());
}

#[test]
fn s32_the_shared_setting_merges_like_any_field_and_reaches_a_new_device() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    settle(&a, &b, &storage);

    a.set_keep_done_minutes(15).unwrap();
    b.set_now_for_tests("2026-10-05T10:01");
    b.set_keep_done_minutes(0).unwrap();
    settle(&a, &b, &storage);
    assert_eq!((a.keep_done_minutes().unwrap(), b.keep_done_minutes().unwrap()), (0, 0));

    let c = device();
    sync(&c, &storage);
    assert_eq!(c.keep_done_minutes().unwrap(), 0);

    // What it means on the device that did not set it: completed there, gone at once here.
    let t = add(&b, "задача");
    b.complete_task(t.id).unwrap();
    settle(&b, &a, &storage);
    assert!(view(&a, Scope::Inbox).is_empty());
}
