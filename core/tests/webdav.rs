//! Sync over HTTP against the minimal WebDAV server from `common/dav.rs`.

mod common;
#[path = "common/dav.rs"]
mod dav;

use common::*;
use lists_core::*;
use tiny_http::Server;

struct Dav {
    url: String,
    root: tempfile::TempDir,
}

fn start() -> Dav {
    let server = Server::http("127.0.0.1:0").unwrap();
    let port = server.server_addr().to_ip().unwrap().port();
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().to_path_buf();
    // The account exists on the server; the collection the user points at does not yet.
    std::fs::create_dir(dir.join("dav")).unwrap();
    std::thread::spawn(move || dav::serve(&server, &dir));
    Dav {
        url: format!("http://127.0.0.1:{port}/dav/user"),
        root,
    }
}

impl Dav {
    /// Requests the server received while `run` was going.
    fn requests(&self, run: impl FnOnce()) -> Vec<String> {
        let log = self.root.path().join(".requests");
        std::fs::write(&log, "").unwrap();
        run();
        let seen = std::fs::read_to_string(&log).unwrap();
        std::fs::remove_file(&log).unwrap();
        seen.lines().map(str::to_string).collect()
    }

    fn storage(&self) -> std::path::PathBuf {
        self.root.path().join("dav/user/lists/v1")
    }
}

fn connect(d: &Device, dav: &Dav, password: &str) {
    d.set_sync_config(SyncConfig::WebDav {
        url: dav.url.clone(),
        user: "user".into(),
    })
    .unwrap();
    d.set_sync_password(Some(password.into()));
}

#[test]
fn two_devices_converge_through_webdav() {
    let dav = start();
    let (a, b) = (device(), device());
    connect(&a, &dav, "secret");
    connect(&b, &dav, "secret");

    let t = add(&a, "через WebDAV");
    let src = tempfile::tempdir().unwrap();
    let file = src.path().join("note.txt");
    std::fs::write(&file, "вложение").unwrap();
    a.add_attachment(t.id.clone(), file.to_string_lossy().into_owned(), None)
        .unwrap();

    let up = a.sync_now().unwrap();
    assert!(up.pushed > 0);
    assert_eq!(up.blobs_uploaded, 1);
    // The client created the collections itself, starting from the missing base.
    assert!(dav.root.path().join("dav/user/lists/v1/vault.json").is_file());

    let down = b.sync_now().unwrap();
    assert!(down.pulled > 0);
    assert_eq!(down.blobs_downloaded, 1);
    assert_eq!(view(&b, Scope::Inbox), ["через WebDAV"]);
    let files = b.attachments(t.id.clone()).unwrap();
    assert_eq!(
        std::fs::read_to_string(files[0].local_path.as_ref().unwrap()).unwrap(),
        "вложение"
    );

    b.set_due(t.id.clone(), Some("2026-10-07".into())).unwrap();
    a.set_title(t.id.clone(), "переименовано".into()).unwrap();
    b.sync_now().unwrap();
    a.sync_now().unwrap();
    b.sync_now().unwrap();
    for d in [&a, &b] {
        let got = d.task(t.id.clone()).unwrap();
        assert_eq!(
            (got.title.as_str(), got.due.as_deref()),
            ("переименовано", Some("2026-10-07"))
        );
    }
    assert_eq!(a.sync_now().unwrap(), SyncReport::default());
}

#[test]
fn compaction_works_over_webdav() {
    let dav = start();
    let (a, b) = (device(), device());
    connect(&a, &dav, "secret");
    connect(&b, &dav, "secret");
    a.set_compact_after_for_tests(2);
    // The first run after connecting publishes a snapshot; these come on top of it.
    for i in 0..5 {
        add(&a, &format!("t{i}"));
        a.sync_now().unwrap();
    }
    let logs = std::fs::read_dir(dav.root.path().join("dav/user/lists/v1/log"))
        .unwrap()
        .flatten()
        .filter(|f| f.file_name().to_string_lossy().ends_with(".jsonl"))
        .count();
    assert!(logs <= 2, "old log files were deleted over HTTP, {logs} left");
    b.sync_now().unwrap();
    assert_eq!(view(&b, Scope::Inbox).len(), 5);
}

#[test]
fn wrong_password_is_reported_and_loses_nothing() {
    let dav = start();
    let a = device();
    connect(&a, &dav, "wrong");
    add(&a, "ждёт");
    let err = a.sync_now().unwrap_err().to_string();
    assert!(err.contains("401") && err.contains("password"), "{err}");
    assert!(a.sync_status().unwrap().pending > 0);

    connect(&a, &dav, "secret");
    assert!(a.sync_now().unwrap().pushed > 0);
}

fn check(url: &str, password: &str) -> Result<ConnectionCheck> {
    check_sync_connection(
        SyncConfig::WebDav {
            url: url.into(),
            user: "user".into(),
        },
        password.into(),
    )
}

// S26
#[test]
fn connection_test_tells_a_ready_storage_from_one_the_first_sync_creates() {
    let dav = start();
    let seen = dav.requests(|| assert_eq!(check(&dav.url, "secret").unwrap(), ConnectionCheck::WillCreate));
    assert!(seen.iter().all(|r| r.starts_with("PROPFIND ")), "{seen:?}");
    assert!(!dav.root.path().join("dav/user").exists());

    std::fs::create_dir(dav.root.path().join("dav/user")).unwrap();
    let seen = dav.requests(|| assert_eq!(check(&dav.url, "secret").unwrap(), ConnectionCheck::Ready));
    assert_eq!(seen, ["PROPFIND /dav/user/ depth=0"]);
}

// S26
#[test]
fn connection_test_names_what_is_wrong() {
    let dav = start();
    let err = check(&dav.url, "wrong").unwrap_err().to_string();
    assert!(err.contains("401") && err.contains("password"), "{err}");

    let err = check(&format!("{}/deeper/still", dav.url), "secret")
        .unwrap_err()
        .to_string();
    assert!(err.contains("nothing is found"), "{err}");

    // A server that knows nothing of WebDAV answers every method the same way.
    let plain = Server::http("127.0.0.1:0").unwrap();
    let port = plain.server_addr().to_ip().unwrap().port();
    std::thread::spawn(move || {
        for request in plain.incoming_requests() {
            request
                .respond(tiny_http::Response::from_string("<html></html>"))
                .unwrap();
        }
    });
    let err = check(&format!("http://127.0.0.1:{port}/files"), "secret")
        .unwrap_err()
        .to_string();
    assert!(err.contains("does not answer as WebDAV"), "{err}");

    // Nobody listens on a port that was just given back.
    let free = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let err = check(&format!("http://127.0.0.1:{free}/files"), "secret")
        .unwrap_err()
        .to_string();
    assert!(err.contains("PROPFIND"), "{err}");

    assert!(check("ftp://example.org", "secret").is_err());
}

// S26
#[test]
fn connection_test_leaves_the_settings_of_the_device_alone() {
    let dav = start();
    let a = device();
    connect(&a, &dav, "secret");
    add(&a, "ждёт");
    let pending = a.sync_status().unwrap().pending;

    assert!(check(&dav.url, "wrong").is_err());
    assert_eq!(check(&dav.url, "secret").unwrap(), ConnectionCheck::WillCreate);

    assert_eq!(a.sync_status().unwrap().pending, pending);
    assert!(!dav.storage().exists());
    // The password the device holds is still the one it was given.
    assert!(a.sync_now().unwrap().pushed > 0);
}

#[test]
fn address_must_be_http() {
    let a = device();
    let bad = SyncConfig::WebDav {
        url: "ftp://example.org".into(),
        user: String::new(),
    };
    assert!(a.set_sync_config(bad).is_err());
    assert_eq!(a.sync_config().unwrap(), SyncConfig::Off);
}

#[test]
fn password_is_kept_out_of_the_database_and_asked_for_again_after_restart() {
    let dav = start();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().to_string_lossy().into_owned();
    {
        let store = Store::open(path.clone()).unwrap();
        store
            .set_sync_config(SyncConfig::WebDav {
                url: dav.url.clone(),
                user: "user".into(),
            })
            .unwrap();
        store.set_sync_password(Some("secret".into()));
        store
            .create_task(NewTask {
                title: "задача".into(),
                ..NewTask::default()
            })
            .unwrap();
        assert!(store.sync_now().unwrap().pushed > 0);
    }
    for file in std::fs::read_dir(dir.path())
        .unwrap()
        .flatten()
        .filter(|f| f.path().is_file())
    {
        let bytes = std::fs::read(file.path()).unwrap();
        assert!(
            !bytes.windows(6).any(|w| w == b"secret"),
            "password found in {:?}",
            file.file_name()
        );
    }

    // A new process knows where to sync but not the password.
    let store = Store::open(path).unwrap();
    assert!(matches!(store.sync_config().unwrap(), SyncConfig::WebDav { .. }));
    let err = store.sync_now().unwrap_err().to_string();
    assert!(err.contains("password is not available"), "{err}");
    store.set_sync_password(Some("secret".into()));
    store.sync_now().unwrap();
}

const LOG: &str = "PROPFIND /dav/user/lists/v1/log/ depth=1";
const SNAP: &str = "PROPFIND /dav/user/lists/v1/snap/ depth=1";

/// A and B in step; A compacts after every file it writes.
fn in_step(dav: &Dav) -> (Device, Device) {
    let (a, b) = (device(), device());
    connect(&a, dav, "secret");
    connect(&b, dav, "secret");
    add(&a, "t1");
    a.sync_now().unwrap();
    b.sync_now().unwrap();
    a.sync_now().unwrap();
    (a, b)
}

#[test]
fn s17_idle_run_is_one_request() {
    let dav = start();
    let (a, b) = in_step(&dav);
    for d in [&a, &b] {
        let seen = dav.requests(|| {
            assert_eq!(d.sync_now().unwrap(), SyncReport::default());
        });
        assert_eq!(seen, [LOG]);
    }
}

#[test]
fn s17_device_left_behind_by_compaction_catches_up_without_listing_snapshots() {
    let dav = start();
    let (a, b) = in_step(&dav);
    a.set_compact_after_for_tests(0);
    for title in ["t2", "t3"] {
        add(&a, title);
        a.sync_now().unwrap();
    }
    let seen = dav.requests(|| {
        b.sync_now().unwrap();
    });
    assert!(
        seen.iter().any(|r| r.starts_with("GET /dav/user/lists/v1/snap/")),
        "{seen:?}"
    );
    assert!(!seen.contains(&SNAP.to_string()), "{seen:?}");
    assert_eq!(view(&b, Scope::Inbox).len(), 3);
}

#[test]
fn s17_snapshot_written_without_a_mark_is_found_by_listing() {
    let dav = start();
    let (a, b) = in_step(&dav);
    a.set_compact_after_for_tests(0);
    add(&a, "t2");
    a.sync_now().unwrap();
    // What a version without marks leaves behind: nothing of A in the log.
    for entry in std::fs::read_dir(dav.storage().join("log")).unwrap().flatten() {
        if entry.file_name().to_string_lossy().starts_with(&a.device_id()) {
            std::fs::remove_file(entry.path()).unwrap();
        }
    }
    let seen = dav.requests(|| {
        b.sync_now().unwrap();
    });
    assert!(seen.contains(&SNAP.to_string()), "{seen:?}");
    assert_eq!(view(&b, Scope::Inbox).len(), 2);
}
