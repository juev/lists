//! Nudges between devices: S18–S21 in docs/specs/sync.md, C22 in docs/specs/caldav.md.

mod common;
#[path = "common/dav.rs"]
mod dav;

use std::sync::{Arc, Mutex};

use common::*;
use lists_core::*;
use tiny_http::{Response, Server};

/// Stands in for a push service: remembers what was posted to each address.
struct Inbox {
    base: String,
    got: Arc<Mutex<Vec<String>>>,
}

impl Inbox {
    fn start() -> Inbox {
        let server = Server::http("127.0.0.1:0").unwrap();
        let base = format!("http://127.0.0.1:{}", server.server_addr().to_ip().unwrap().port());
        let got = Arc::new(Mutex::new(Vec::new()));
        let seen = got.clone();
        std::thread::spawn(move || {
            for mut request in server.incoming_requests() {
                let mut body = String::new();
                request.as_reader().read_to_string(&mut body).unwrap();
                seen.lock()
                    .unwrap()
                    .push(format!("{} {} {body}", request.method(), request.url()));
                request.respond(Response::empty(200)).unwrap();
            }
        });
        Inbox { base, got }
    }

    fn address(&self, name: &str) -> Option<String> {
        Some(format!("{}/{name}", self.base))
    }

    /// What arrived since the last look.
    fn take(&self) -> Vec<String> {
        std::mem::take(&mut self.got.lock().unwrap())
    }
}

fn folder(storage: &tempfile::TempDir) -> SyncConfig {
    SyncConfig::Folder {
        path: storage.path().to_string_lossy().into_owned(),
    }
}

/// The scenario every kind of storage has to pass.
fn nudges_follow_uploads(a: &Device, b: &Device, inbox: &Inbox) {
    a.set_push_endpoint(inbox.address("a")).unwrap();
    b.set_push_endpoint(inbox.address("b")).unwrap();
    a.sync_now().unwrap();
    b.sync_now().unwrap();
    a.sync_now().unwrap();
    inbox.take();

    // S19: an upload nudges the others, not the sender.
    let task = add(a, "от A");
    a.sync_now().unwrap();
    assert_eq!(inbox.take(), ["POST /b sync"]);

    // S21: reading is not an upload, and neither is a run with nothing to do.
    b.sync_now().unwrap();
    a.sync_now().unwrap();
    b.sync_now().unwrap();
    assert_eq!(view(b, Scope::Inbox), ["от A"]);
    assert_eq!(inbox.take(), Vec::<String>::new());

    // S18: a device that stops listening is no longer nudged.
    b.set_push_endpoint(None).unwrap();
    b.sync_now().unwrap();
    a.set_title(task.id.clone(), "от A, изменено".into()).unwrap();
    a.sync_now().unwrap();
    assert_eq!(inbox.take(), Vec::<String>::new());

    // S20: an address nobody listens at does not get in the way.
    b.set_push_endpoint(Some("http://127.0.0.1:9/nobody".into())).unwrap();
    b.sync_now().unwrap();
    a.set_title(task.id.clone(), "от A, ещё раз".into()).unwrap();
    assert!(a.sync_now().unwrap().pushed > 0);
    b.sync_now().unwrap();
    assert_eq!(b.task(task.id).unwrap().title, "от A, ещё раз");
}

#[test]
fn s18_s21_through_a_folder() {
    let storage = tempfile::tempdir().unwrap();
    let inbox = Inbox::start();
    let (a, b) = (device(), device());
    a.set_sync_config(folder(&storage)).unwrap();
    b.set_sync_config(folder(&storage)).unwrap();
    nudges_follow_uploads(&a, &b, &inbox);
}

#[test]
fn s18_record_in_the_storage_follows_the_address() {
    let storage = tempfile::tempdir().unwrap();
    let a = device();
    a.set_sync_config(folder(&storage)).unwrap();
    let record = storage
        .path()
        .join("lists/v1/push")
        .join(format!("{}.json", a.device_id()));

    a.set_push_endpoint(Some("https://push.example.org/one".into()))
        .unwrap();
    a.sync_now().unwrap();
    assert!(std::fs::read_to_string(&record)
        .unwrap()
        .contains("https://push.example.org/one"));
    a.set_push_endpoint(Some("https://push.example.org/two".into()))
        .unwrap();
    a.sync_now().unwrap();
    assert!(std::fs::read_to_string(&record)
        .unwrap()
        .contains("https://push.example.org/two"));
    a.set_push_endpoint(None).unwrap();
    a.sync_now().unwrap();
    assert!(!record.exists());

    assert!(a.set_push_endpoint(Some("file:///etc/passwd".into())).is_err());
    assert_eq!(a.push_endpoint().unwrap(), None);
}

struct Dav {
    url: String,
    root: tempfile::TempDir,
}

fn caldav() -> Dav {
    let server = Server::http("127.0.0.1:0").unwrap();
    let port = server.server_addr().to_ip().unwrap().port();
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().to_path_buf();
    std::fs::create_dir(dir.join("cal")).unwrap();
    std::thread::spawn(move || dav::serve(&server, &dir));
    Dav {
        url: format!("http://127.0.0.1:{port}/cal"),
        root,
    }
}

fn join(dav: &Dav) -> Device {
    let d = device();
    d.set_sync_config(SyncConfig::CalDav {
        url: dav.url.clone(),
        user: "user".into(),
    })
    .unwrap();
    d.set_sync_password(Some("secret".into()));
    d
}

#[test]
fn c22_through_caldav() {
    let dav = caldav();
    let inbox = Inbox::start();
    nudges_follow_uploads(&join(&dav), &join(&dav), &inbox);
}

#[test]
fn c22_server_that_drops_custom_properties_gets_no_nudges_and_no_repeated_writes() {
    let dav = caldav();
    std::fs::write(dav.root.path().join(".no-custom-props"), "").unwrap();
    let inbox = Inbox::start();
    let (a, b) = (join(&dav), join(&dav));
    a.set_push_endpoint(inbox.address("a")).unwrap();
    b.set_push_endpoint(inbox.address("b")).unwrap();
    for _ in 0..2 {
        a.sync_now().unwrap();
        b.sync_now().unwrap();
    }
    add(&a, "от A");
    a.sync_now().unwrap();
    assert_eq!(inbox.take(), Vec::<String>::new());

    let log = dav.root.path().join(".requests");
    std::fs::write(&log, "").unwrap();
    a.sync_now().unwrap();
    a.sync_now().unwrap();
    let seen = std::fs::read_to_string(&log).unwrap();
    assert!(!seen.contains("PROPPATCH"), "{seen}");
}

/// Stands in for an ntfy server: `POST /<topic>` reaches everyone who holds
/// `GET /<topic>/json` open.
struct Ntfy {
    base: String,
    listeners: Arc<Mutex<Vec<(String, std::net::TcpStream)>>>,
}

impl Ntfy {
    fn start() -> Ntfy {
        use std::io::{BufRead, BufReader, Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let listeners: Arc<Mutex<Vec<(String, std::net::TcpStream)>>> = Arc::default();
        let held = listeners.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let held = held.clone();
                std::thread::spawn(move || {
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut first = String::new();
                    reader.read_line(&mut first).unwrap();
                    let mut length = 0;
                    loop {
                        let mut header = String::new();
                        reader.read_line(&mut header).unwrap();
                        if header.trim().is_empty() {
                            break;
                        }
                        if let Some(value) = header.to_ascii_lowercase().strip_prefix("content-length:") {
                            length = value.trim().parse().unwrap();
                        }
                    }
                    let mut body = vec![0; length];
                    reader.read_exact(&mut body).unwrap();
                    let mut stream = stream;
                    let mut parts = first.split_whitespace();
                    match (parts.next(), parts.next()) {
                        (Some("GET"), Some(path)) if path.ends_with("/json") => {
                            stream
                                .write_all(b"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n{\"event\":\"open\"}\n")
                                .unwrap();
                            let topic = path.trim_end_matches("/json").to_string();
                            held.lock().unwrap().push((topic, stream));
                        }
                        (Some("POST"), Some(path)) => {
                            for (topic, listener) in held.lock().unwrap().iter_mut() {
                                if topic == path {
                                    let _ = listener
                                        .write_all(b"{\"id\":\"x\",\"event\":\"message\",\"message\":\"sync\"}\n");
                                }
                            }
                            stream
                                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
                                .unwrap();
                        }
                        _ => {}
                    }
                });
            }
        });
        Ntfy { base, listeners }
    }

    /// Waits until `count` subscriptions are open.
    fn wait_for_listeners(&self, count: usize) {
        for _ in 0..500 {
            if self.listeners.lock().unwrap().len() >= count {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        panic!("nobody subscribed");
    }

    fn drop_listeners(&self) {
        for (_, stream) in self.listeners.lock().unwrap().drain(..) {
            let _ = stream.shutdown(std::net::Shutdown::Both);
        }
    }
}

/// Starts the wait on a thread of its own; the answer arrives on the channel.
fn waiting(d: &Device) -> std::sync::mpsc::Receiver<bool> {
    let (tx, rx) = std::sync::mpsc::channel();
    let store = d.store.clone();
    std::thread::spawn(move || {
        let _ = tx.send(store.wait_for_nudge());
    });
    rx
}

const SOON: std::time::Duration = std::time::Duration::from_secs(5);

#[test]
fn s22_an_edit_elsewhere_wakes_the_waiting_device() {
    let storage = tempfile::tempdir().unwrap();
    let ntfy = Ntfy::start();
    let (a, b) = (device(), device());
    for d in [&a, &b] {
        d.set_sync_config(folder(&storage)).unwrap();
        d.set_push_server(Some(format!("{}/", ntfy.base))).unwrap();
        d.sync_now().unwrap();
    }
    let topic = b.push_endpoint().unwrap().unwrap();
    assert!(
        topic.starts_with(&format!("{}/", ntfy.base)) && topic.len() == ntfy.base.len() + 33,
        "{topic}"
    );
    assert_ne!(a.push_endpoint().unwrap(), b.push_endpoint().unwrap());

    let woken = waiting(&b);
    ntfy.wait_for_listeners(1);
    add(&a, "от A");
    a.sync_now().unwrap();
    assert!(woken.recv_timeout(SOON).unwrap(), "the nudge arrives at once");
    b.sync_now().unwrap();
    assert_eq!(view(&b, Scope::Inbox), ["от A"]);

    // The topic is chosen once: turning the setting off and on keeps the address.
    b.set_push_server(None).unwrap();
    assert_eq!(b.push_endpoint().unwrap(), None);
    b.set_push_server(Some(ntfy.base.clone())).unwrap();
    assert_eq!(b.push_endpoint().unwrap().unwrap(), topic);
}

#[test]
fn s23_a_broken_subscription_counts_as_a_nudge_and_a_missing_server_as_none() {
    let ntfy = Ntfy::start();
    let b = device();
    b.set_push_retry_for_tests(50);
    assert!(!b.wait_for_nudge(), "no server is set");

    b.set_push_server(Some(ntfy.base.clone())).unwrap();
    let woken = waiting(&b);
    ntfy.wait_for_listeners(1);
    ntfy.drop_listeners();
    assert!(woken.recv_timeout(SOON).unwrap());

    b.set_push_server(Some("http://127.0.0.1:9".into())).unwrap();
    assert!(!b.wait_for_nudge(), "nobody answers there");
    assert!(b.set_push_server(Some("ntfy.sh".into())).is_err());
}
