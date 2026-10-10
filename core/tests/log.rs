mod common;

use common::*;
use lists_core::{LogLevel, NewTask, Store, SyncConfig};

fn log_of(device: &Device) -> String {
    std::fs::read_to_string(device.dir().join("log.txt")).unwrap_or_default()
}

fn folder(dir: &tempfile::TempDir) -> SyncConfig {
    SyncConfig::Folder {
        path: dir.path().to_string_lossy().into_owned(),
    }
}

/// A WebDAV server that is not there: nothing listens on port 1.
fn unreachable() -> SyncConfig {
    SyncConfig::WebDav {
        url: "http://127.0.0.1:1/dav".into(),
        user: "me".into(),
    }
}

#[test]
fn r102_a_new_device_logs_errors_and_has_no_file() {
    let a = device();
    assert_eq!(a.log_level(), LogLevel::Error);
    assert!(a.log_files().is_empty());
    assert!(!a.dir().join("log.txt").exists());
}

#[test]
fn r102_a_failed_sync_is_an_error_line() {
    let a = device();
    a.set_sync_config(unreachable()).unwrap();
    a.set_sync_password(Some("pw-123".into()));
    assert!(a.sync_now().is_err());
    let log = log_of(&a);
    let line = log.lines().next().expect("a line in the log");
    assert!(line.contains(" ERROR sync: "), "{line}");
    assert_eq!(log.lines().count(), 1);
}

#[test]
fn r102_a_sync_that_went_through_is_an_event_and_not_an_error() {
    let storage = tempfile::tempdir().unwrap();
    let a = device();
    a.set_sync_config(folder(&storage)).unwrap();
    add(&a, "one");
    a.sync_now().unwrap();
    assert_eq!(log_of(&a), "", "the default level takes errors only");

    a.set_log_level(LogLevel::Info).unwrap();
    add(&a, "two");
    a.sync_now().unwrap();
    let log = log_of(&a);
    assert!(log.contains(" INFO log: level set to info"), "{log}");
    assert!(log.contains(" INFO sync: run finished: 0 received, "), "{log}");
}

#[test]
fn r102_a_run_that_changed_nothing_is_said_at_the_detailed_level_only() {
    let storage = tempfile::tempdir().unwrap();
    let a = device();
    a.set_sync_config(folder(&storage)).unwrap();
    a.set_log_level(LogLevel::Info).unwrap();
    a.sync_now().unwrap();
    assert!(!log_of(&a).contains("sync:"), "{}", log_of(&a));

    a.set_log_level(LogLevel::Debug).unwrap();
    a.sync_now().unwrap();
    assert!(
        log_of(&a).contains(" DEBUG sync: run finished: 0 received, 0 sent"),
        "{}",
        log_of(&a)
    );
}

#[test]
fn r102_nothing_is_written_when_the_log_is_off() {
    let a = device();
    a.set_log_level(LogLevel::Off).unwrap();
    a.set_sync_config(unreachable()).unwrap();
    assert!(a.sync_now().is_err());
    a.log(LogLevel::Error, "app".into(), "a failure".into());
    assert!(a.log_files().is_empty());
}

#[test]
fn r102_the_level_is_kept_on_the_device() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().to_string_lossy().into_owned();
    Store::open(path.clone())
        .unwrap()
        .set_log_level(LogLevel::Debug)
        .unwrap();
    assert_eq!(Store::open(path).unwrap().log_level(), LogLevel::Debug);
}

#[test]
fn r102_the_level_is_not_synced() {
    let storage = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    a.set_sync_config(folder(&storage)).unwrap();
    b.set_sync_config(folder(&storage)).unwrap();
    a.set_log_level(LogLevel::Debug).unwrap();
    add(&a, "one");
    a.sync_now().unwrap();
    b.sync_now().unwrap();
    assert_eq!(b.log_level(), LogLevel::Error);
}

#[test]
fn r102_a_line_from_the_app_follows_the_level_and_stays_one_line() {
    let a = device();
    a.log(LogLevel::Info, "app".into(), "started".into());
    assert_eq!(log_of(&a), "");
    a.log(LogLevel::Error, "app".into(), "first\nsecond".into());
    let log = log_of(&a);
    assert_eq!(log.lines().count(), 1);
    assert!(log.trim_end().ends_with(" ERROR app: first second"), "{log}");
    // The moment comes first: date, T, time to the second.
    let moment = log.split(' ').next().unwrap();
    assert_eq!(moment.len(), "2026-10-05T10:00:00".len());
    assert_eq!(&moment[10..11], "T");
}

#[test]
fn r102_a_file_over_the_limit_becomes_the_previous_one() {
    let a = device();
    let big = "x".repeat(200 * 1024);
    for _ in 0..6 {
        a.log(LogLevel::Error, "app".into(), big.clone());
    }
    let previous = a.dir().join("log.1.txt");
    assert!(!previous.exists(), "six lines of 200 KB cross 1 MB only with the sixth");
    a.log(LogLevel::Error, "app".into(), "after the limit".into());
    assert!(std::fs::metadata(&previous).unwrap().len() > (1 << 20));
    assert_eq!(log_of(&a).lines().count(), 1);
    assert!(log_of(&a).contains("after the limit"));
    let files = a.log_files();
    assert_eq!(files.len(), 2);
    assert!(
        files[0].ends_with("log.1.txt") && files[1].ends_with("log.txt"),
        "{files:?}"
    );
}

#[test]
fn r102_clearing_removes_both_files() {
    let a = device();
    let big = "x".repeat(600 * 1024);
    for _ in 0..3 {
        a.log(LogLevel::Error, "app".into(), big.clone());
    }
    assert_eq!(a.log_files().len(), 2);
    a.clear_log().unwrap();
    assert!(a.log_files().is_empty());
    a.clear_log().unwrap();
}

#[test]
fn r102_the_log_holds_neither_the_tasks_nor_the_password() {
    let storage = tempfile::tempdir().unwrap();
    let a = device();
    a.set_log_level(LogLevel::Debug).unwrap();
    a.create_task(NewTask {
        title: "Секрет".into(),
        notes: "тайная заметка".into(),
        ..NewTask::default()
    })
    .unwrap();
    a.set_sync_config(folder(&storage)).unwrap();
    a.sync_now().unwrap();
    a.sync_attachments().unwrap();
    a.create_backup().unwrap();
    a.set_sync_config(unreachable()).unwrap();
    a.set_sync_password(Some("pw-123".into()));
    assert!(a.sync_now().is_err());

    let log = log_of(&a);
    assert!(log.contains(" INFO sync: run finished"), "{log}");
    assert!(log.contains(" INFO backup: created "), "{log}");
    assert!(log.contains(" ERROR sync: "), "{log}");
    for hidden in ["Секрет", "тайная", "pw-123"] {
        assert!(!log.contains(hidden), "{hidden} is in the log: {log}");
    }
}

#[test]
fn r102_a_backup_does_not_carry_the_log() {
    let a = device();
    add(&a, "one");
    a.log(LogLevel::Error, "app".into(), "kept out of the backup".into());
    let backup = a.create_backup().unwrap();
    let archive = std::fs::read(backup.path).unwrap();
    let needle = b"log.txt";
    assert!(!archive.windows(needle.len()).any(|w| w == needle));
}
