//! Backups and restoring: R87–R90 in docs/specs/product.md, S40 in docs/specs/sync.md.

mod common;

use std::io::Write;

use common::*;
use lists_core::sync::remote::DirRemote;
use lists_core::*;
use tempfile::TempDir;

fn sync(d: &Device, storage: &TempDir) -> SyncReport {
    d.sync_with(&DirRemote::new(storage.path())).unwrap()
}

fn folder(storage: &TempDir) -> SyncConfig {
    SyncConfig::Folder {
        path: storage.path().to_string_lossy().into_owned(),
    }
}

fn sorted(mut titles: Vec<String>) -> Vec<String> {
    titles.sort();
    titles
}

fn attach(d: &Device, task: &TaskItem, name: &str, content: &[u8]) -> Attachment {
    let src = tempfile::tempdir().unwrap();
    let file = src.path().join(name);
    std::fs::write(&file, content).unwrap();
    d.add_attachment(task.id.clone(), file.to_string_lossy().into_owned(), None)
        .unwrap()
}

/// Everything a user can see, in a form two devices can compare.
fn dump(d: &Device) -> Vec<String> {
    fn walk(d: &Device, tasks: Vec<TaskItem>, depth: usize, out: &mut Vec<String>) {
        for t in tasks {
            let files: Vec<String> = d
                .attachments(t.id.clone())
                .unwrap()
                .into_iter()
                .map(|a| format!("{}:{}:{}", a.name, a.sha256, a.local_path.is_some()))
                .collect();
            out.push(format!(
                "{}{} | {} | due={:?} prio={:?} done={} tags={:?} repeat={} notes={:?} files={:?}",
                "  ".repeat(depth),
                t.id,
                t.title,
                t.due,
                t.priority,
                t.done.is_some(),
                t.tags,
                t.repeat.is_some(),
                t.notes,
                files
            ));
            walk(d, d.subtasks(t.id).unwrap(), depth + 1, out);
        }
    }
    let mut out = Vec::new();
    for list in d.lists().unwrap() {
        out.push(format!("# {} | {} | {}", list.id, list.name, list.color));
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
            .map(|t| format!("  {} | {}", t.id, t.title)),
    );
    out.push(format!("# keep done {:?}", d.keep_done().unwrap()));
    out
}

/// A device with a bit of everything a backup has to carry.
fn furnished() -> Device {
    let d = device();
    let work = d.create_list("Работа".into()).unwrap();
    let report = add(&d, "отчёт");
    d.move_to_list(report.id.clone(), work.id).unwrap();
    d.add_tag(report.id.clone(), "срочно".into()).unwrap();
    d.set_due(report.id.clone(), Some("2026-10-12".into())).unwrap();
    d.set_notes(report.id.clone(), "черновик у Оли".into()).unwrap();
    add_sub(&d, &report, "собрать цифры");
    attach(&d, &report, "цифры.txt", b"1 2 3");
    let gone = add(&d, "удалённая");
    d.delete_task(gone.id).unwrap();
    let done = add(&d, "сделанная");
    d.complete_task(done.id).unwrap();
    d.set_keep_done(KeepDone::EndOfDay).unwrap();
    d
}

#[test]
fn r87_r90_a_backup_restores_on_a_clean_install() {
    let old = furnished();
    let backup = old.create_backup().unwrap();
    assert_eq!(backup.name, "Lists_(2026-10-05-10_00_00).listsbackup");
    assert_eq!(backup.created, NOW);
    assert!(backup.size > 0);

    let fresh = device();
    fresh.restore_backup(backup.path.clone(), false).unwrap();
    assert_eq!(dump(&fresh), dump(&old));
    // The content came with the backup and opens.
    let report = fresh
        .tasks(Scope::Search {
            text: "отчёт".into()
        })
        .unwrap()
        .remove(0);
    let file = fresh.attachments(report.id).unwrap().remove(0);
    assert_eq!(std::fs::read(file.local_path.unwrap()).unwrap(), b"1 2 3");
    // A clean install had nothing to keep before the restore.
    assert!(fresh.backups().unwrap().is_empty());
    // The restored device is not the one that made the backup (S40).
    assert_ne!(fresh.device_id(), old.device_id());
}

#[test]
fn r87_what_belongs_to_the_device_is_not_in_the_backup() {
    let storage = tempfile::tempdir().unwrap();
    let old = furnished();
    old.set_sync_config(folder(&storage)).unwrap();
    old.set_backup_settings(BackupSettings {
        every_hours: 48,
        keep: 20,
    })
    .unwrap();
    let backup = old.create_backup().unwrap();

    let fresh = device();
    fresh.restore_backup(backup.path, false).unwrap();
    assert_eq!(fresh.sync_config().unwrap(), SyncConfig::Off);
    assert_eq!(
        fresh.backup_settings().unwrap(),
        BackupSettings {
            every_hours: 24,
            keep: 5
        }
    );
}

#[test]
fn r90_restoring_replaces_the_data_and_keeps_what_was_there_as_a_backup() {
    let d = furnished();
    let before = dump(&d);
    let backup = d.create_backup().unwrap();

    d.set_now_for_tests("2026-10-06T09:00");
    let work = d.lists().unwrap().into_iter().find(|l| l.name == "Работа").unwrap();
    d.delete_list(work.id).unwrap();
    add(&d, "лишняя");
    let changed = dump(&d);
    assert_ne!(changed, before);

    d.restore_backup(backup.path, false).unwrap();
    // Seen at the moment of the first look: a completed task leaves its list with time (R68).
    d.set_now_for_tests(NOW);
    assert_eq!(dump(&d), before);
    // The state that was replaced is the newest backup now.
    let kept = d.backups().unwrap();
    assert_eq!(kept.len(), 2);
    assert_eq!(kept[0].created, "2026-10-06T09:00");
    d.set_now_for_tests("2026-10-06T09:00");
    d.restore_backup(kept[0].path.clone(), false).unwrap();
    assert_eq!(dump(&d), changed);
}

#[test]
fn r90_a_file_that_is_no_backup_changes_nothing() {
    let d = furnished();
    let before = dump(&d);
    let dir = tempfile::tempdir().unwrap();

    let text = dir.path().join("notes.txt");
    std::fs::write(&text, "not a zip").unwrap();
    assert!(d.restore_backup(text.to_string_lossy().into_owned(), false).is_err());

    let zip_with = |name: &str, entries: &[(&str, &[u8])]| {
        let path = dir.path().join(name);
        let mut zip = zip::ZipWriter::new(std::fs::File::create(&path).unwrap());
        for (entry, body) in entries {
            zip.start_file(*entry, zip::write::SimpleFileOptions::default())
                .unwrap();
            zip.write_all(body).unwrap();
        }
        zip.finish().unwrap();
        path.to_string_lossy().into_owned()
    };
    let other = zip_with("other.zip", &[("2do.db", b"x")]);
    assert!(d.restore_backup(other, false).is_err());
    let newer = zip_with(
        "newer.listsbackup",
        &[(
            "manifest.json",
            br#"{"format":2,"created":"2027-01-01T00:00:00","fields":0,"blobs":0}"#,
        )],
    );
    let error = d.restore_backup(newer, false).unwrap_err().to_string();
    assert!(error.contains("format 2"), "{error}");
    let broken = zip_with(
        "broken.listsbackup",
        &[
            (
                "manifest.json",
                br#"{"format":1,"created":"2026-01-01T00:00:00","fields":1,"blobs":0}"#,
            ),
            ("lists.sqlite", b"this is not a database"),
        ],
    );
    assert!(d.restore_backup(broken, false).is_err());

    assert_eq!(dump(&d), before);
    assert!(d.backups().unwrap().is_empty(), "nothing was about to be replaced");
}

#[test]
fn r90_content_that_does_not_match_its_name_is_not_taken() {
    let old = device();
    let t = add(&old, "с файлом");
    let file = attach(&old, &t, "a.txt", b"honest");
    let backup = old.create_backup().unwrap();

    // The same archive with the content of the attachment replaced.
    let dir = tempfile::tempdir().unwrap();
    let forged = dir.path().join("forged.listsbackup");
    let mut source = zip::ZipArchive::new(std::fs::File::open(&backup.path).unwrap()).unwrap();
    let mut out = zip::ZipWriter::new(std::fs::File::create(&forged).unwrap());
    for i in 0..source.len() {
        let mut entry = source.by_index(i).unwrap();
        let name = entry.name().to_string();
        out.start_file(name.as_str(), zip::write::SimpleFileOptions::default())
            .unwrap();
        if name.starts_with("blobs/") {
            out.write_all(b"forged").unwrap();
        } else {
            std::io::copy(&mut entry, &mut out).unwrap();
        }
    }
    out.start_file("blobs/../../escaped", zip::write::SimpleFileOptions::default())
        .unwrap();
    out.write_all(b"x").unwrap();
    out.finish().unwrap();

    let fresh = device();
    fresh
        .restore_backup(forged.to_string_lossy().into_owned(), false)
        .unwrap();
    let got = fresh.attachments(t.id).unwrap().remove(0);
    assert_eq!(got.sha256, file.sha256);
    assert!(
        got.local_path.is_none(),
        "the record is there, the forged content is not"
    );
    assert!(!fresh.dir().join("escaped").exists());
    assert!(!fresh.dir().parent().unwrap().join("escaped").exists());
}

#[test]
fn r88_automatic_backups_follow_the_schedule_and_the_oldest_go() {
    let d = device();
    assert_eq!(
        d.backup_settings().unwrap(),
        BackupSettings {
            every_hours: 24,
            keep: 5
        }
    );
    // Nothing to keep yet.
    assert!(d.backup_if_due().unwrap().is_none());
    add(&d, "первая");

    assert!(d.backup_if_due().unwrap().is_some(), "the first one is made at once");
    assert!(d.backup_if_due().unwrap().is_none());
    d.set_now_for_tests("2026-10-06T09:59");
    assert!(d.backup_if_due().unwrap().is_none(), "a minute short of 24 hours");
    for day in 6..=11 {
        d.set_now_for_tests(&format!("2026-10-{day:02}T10:00"));
        assert!(d.backup_if_due().unwrap().is_some());
    }
    let kept: Vec<String> = d.backups().unwrap().into_iter().map(|b| b.created).collect();
    assert_eq!(
        kept,
        [
            "2026-10-11T10:00",
            "2026-10-10T10:00",
            "2026-10-09T10:00",
            "2026-10-08T10:00",
            "2026-10-07T10:00"
        ]
    );

    // A backup made by hand takes a place too, and does not put the next automatic one off.
    d.set_now_for_tests("2026-10-11T18:00");
    d.create_backup().unwrap();
    let kept = d.backups().unwrap();
    assert_eq!(kept.len(), 5);
    assert_eq!(kept[0].created, "2026-10-11T18:00");
    assert_eq!(kept[4].created, "2026-10-08T10:00");
    d.set_now_for_tests("2026-10-12T10:00");
    assert!(d.backup_if_due().unwrap().is_some());

    d.set_backup_settings(BackupSettings {
        every_hours: 48,
        keep: 5,
    })
    .unwrap();
    d.set_now_for_tests("2026-10-13T10:00");
    assert!(d.backup_if_due().unwrap().is_none());
    d.set_now_for_tests("2026-10-14T10:00");
    assert!(d.backup_if_due().unwrap().is_some());

    d.set_backup_settings(BackupSettings {
        every_hours: 0,
        keep: 5,
    })
    .unwrap();
    d.set_now_for_tests("2026-11-14T10:00");
    assert!(d.backup_if_due().unwrap().is_none(), "off");
    assert!(d
        .set_backup_settings(BackupSettings {
            every_hours: 12,
            keep: 5
        })
        .is_err());
    assert!(d
        .set_backup_settings(BackupSettings {
            every_hours: 24,
            keep: 7
        })
        .is_err());
}

#[test]
fn r89_backups_are_listed_and_deleted_by_name() {
    let d = device();
    add(&d, "задача");
    let first = d.create_backup().unwrap();
    // Two within one second are two files.
    let second = d.create_backup().unwrap();
    assert_ne!(first.name, second.name);
    assert_eq!(d.backups().unwrap().len(), 2);

    d.delete_backup(first.name.clone()).unwrap();
    assert_eq!(d.backups().unwrap(), [second]);
    d.delete_backup(first.name).unwrap();
    // Only what this folder holds under a backup's name can be named.
    assert!(d.delete_backup("../lists.sqlite".into()).is_err());
    assert!(d.delete_backup("lists.sqlite".into()).is_err());
    assert!(d.dir().join("lists.sqlite").exists());
}

#[test]
fn s40_a_restore_merged_with_the_storage_keeps_what_happened_since() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    let t = add(&a, "один");
    let later_gone = add(&a, "удалят позже");
    sync(&a, &storage);
    sync(&b, &storage);
    let backup = a.create_backup().unwrap();

    b.set_title(t.id.clone(), "два".into()).unwrap();
    b.delete_task(later_gone.id.clone()).unwrap();
    sync(&b, &storage);
    sync(&a, &storage);

    a.restore_backup(backup.path, false).unwrap();
    assert_eq!(a.task(t.id.clone()).unwrap().title, "один");
    sync(&a, &storage);
    sync(&b, &storage);
    for d in [&a, &b] {
        assert_eq!(d.task(t.id.clone()).unwrap().title, "два", "the later edit wins");
        assert_eq!(view(d, Scope::Trash), ["удалят позже"]);
    }
}

#[test]
fn s40_a_restore_put_over_the_storage_reaches_every_device() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    a.set_sync_config(folder(&storage)).unwrap();
    b.set_sync_config(folder(&storage)).unwrap();
    let t = add(&a, "один");
    let later_gone = add(&a, "удалят позже");
    a.sync_now().unwrap();
    b.sync_now().unwrap();
    let backup = a.create_backup().unwrap();
    let was = a.device_id();

    b.set_title(t.id.clone(), "два".into()).unwrap();
    b.delete_task(later_gone.id).unwrap();
    add(&b, "появилась позже");
    b.sync_now().unwrap();
    a.sync_now().unwrap();

    a.restore_backup(backup.path, true).unwrap();
    assert_ne!(a.device_id(), was);
    assert_eq!(a.sync_config().unwrap(), folder(&storage), "the sync settings stay");
    a.sync_now().unwrap();
    b.sync_now().unwrap();
    for d in [&a, &b] {
        assert_eq!(d.task(t.id.clone()).unwrap().title, "один");
        assert_eq!(sorted(view(d, Scope::All)), ["один", "удалят позже"]);
        assert_eq!(view(d, Scope::Trash), ["появилась позже"]);
    }
    // The device goes on under its new name.
    add(&a, "после");
    a.sync_now().unwrap();
    b.sync_now().unwrap();
    assert_eq!(sorted(view(&b, Scope::All)), ["один", "после", "удалят позже"]);
}

#[test]
fn s40_a_backup_restored_on_another_device_does_not_share_its_name() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    a.set_sync_config(folder(&storage)).unwrap();
    add(&a, "с A");
    a.sync_now().unwrap();
    let backup = a.create_backup().unwrap();

    b.set_sync_config(folder(&storage)).unwrap();
    b.restore_backup(backup.path, false).unwrap();
    assert_ne!(a.device_id(), b.device_id());
    add(&b, "с B");
    add(&a, "ещё с A");
    b.sync_now().unwrap();
    a.sync_now().unwrap();
    b.sync_now().unwrap();
    for d in [&a, &b] {
        assert_eq!(sorted(view(d, Scope::All)), ["ещё с A", "с A", "с B"]);
    }
}

#[test]
fn r88_two_looks_at_the_schedule_at_once_make_one_backup() {
    let d = device();
    add(&d, "задача");
    let made: usize = std::thread::scope(|scope| {
        let looks: Vec<_> = (0..8)
            .map(|_| scope.spawn(|| d.backup_if_due().unwrap().is_some()))
            .collect();
        looks.into_iter().map(|l| l.join().unwrap() as usize).sum()
    });
    assert_eq!(made, 1);
    assert_eq!(d.backups().unwrap().len(), 1);
}
