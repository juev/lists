//! Sync through CalDAV: docs/specs/caldav.md. The server is `common/dav.rs`;
//! "another client" is played by editing the objects in its folder directly.

mod common;
#[path = "common/dav.rs"]
mod dav;

use std::path::PathBuf;

use common::*;
use lists_core::*;
use tiny_http::Server;

struct Dav {
    url: String,
    root: tempfile::TempDir,
}

impl Dav {
    fn home(&self) -> PathBuf {
        self.root.path().join("cal")
    }

    /// Path of the object of a task that lives in the inbox calendar.
    fn object(&self, task_id: &str) -> PathBuf {
        self.home().join("lists-inbox").join(format!("{task_id}.ics"))
    }

    fn read(&self, task_id: &str) -> String {
        std::fs::read_to_string(self.object(task_id)).unwrap()
    }

    /// Rewrites an object the way another client would: unfolded lines in, same text out.
    fn edit(&self, task_id: &str, change: impl Fn(Vec<String>) -> Vec<String>) {
        let unfolded = self.read(task_id).replace("\r\n ", "");
        let lines = change(
            unfolded
                .split("\r\n")
                .filter(|l| !l.is_empty())
                .map(str::to_string)
                .collect(),
        );
        std::fs::write(self.object(task_id), lines.join("\r\n") + "\r\n").unwrap();
    }

    fn objects(&self) -> usize {
        std::fs::read_dir(self.home().join("lists-inbox")).map_or(0, |d| {
            d.flatten()
                .filter(|e| e.file_name().to_string_lossy().ends_with(".ics"))
                .count()
        })
    }
}

fn start() -> Dav {
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

fn connect(d: &Device, dav: &Dav) {
    d.set_sync_config(SyncConfig::CalDav {
        url: dav.url.clone(),
        user: "user".into(),
    })
    .unwrap();
    d.set_sync_password(Some("secret".into()));
}

fn pair(dav: &Dav) -> (Device, Device) {
    let (a, b) = (device(), device());
    connect(&a, dav);
    connect(&b, dav);
    (a, b)
}

fn settle(a: &Device, b: &Device) {
    a.sync_now().unwrap();
    b.sync_now().unwrap();
    a.sync_now().unwrap();
}

fn daily() -> Repeat {
    Repeat {
        freq: Freq::Daily,
        interval: 1,
        weekdays: vec![],
        monthday: None,
        nth: None,
        nth_weekday: None,
        from_done: false,
        count: None,
        until: None,
    }
}

#[test]
fn c2_c4_tasks_become_objects_other_clients_can_read() {
    let dav = start();
    let (a, b) = pair(&dav);
    let top = a
        .create_task(NewTask {
            title: "Купить молоко, хлеб".into(),
            due: Some("2026-10-06T18:30".into()),
            priority: Some(Priority::High),
            tags: vec!["дом".into()],
            ..NewTask::default()
        })
        .unwrap();
    a.set_repeat(top.id.clone(), Some(daily())).unwrap();
    a.set_remind(top.id.clone(), Some("2026-10-06T18:00".into())).unwrap();
    let sub = add_sub(&a, &top, "зайти в магазин");

    let up = a.sync_now().unwrap();
    assert!(up.pushed >= 2);
    let text = dav.read(&top.id).replace("\r\n ", "");
    for expected in [
        "BEGIN:VTODO",
        "SUMMARY:Купить молоко\\, хлеб",
        "DUE:20261006T183000",
        "PRIORITY:1",
        "CATEGORIES:дом",
        "RRULE:FREQ=DAILY",
        "X-LISTS-STATE:",
    ] {
        assert!(text.contains(expected), "{expected} in\n{text}");
    }
    assert!(dav
        .read(&sub.id)
        .contains(&format!("RELATED-TO;RELTYPE=PARENT:{}", top.id)));

    assert!(b.sync_now().unwrap().pulled > 0);
    let got = b.task(top.id.clone()).unwrap();
    assert_eq!(
        (got.title.as_str(), got.due.as_deref(), got.priority),
        ("Купить молоко, хлеб", Some("2026-10-06T18:30"), Priority::High)
    );
    assert_eq!(got.tags, ["дом"]);
    assert!(got.repeat.is_some());
    assert_eq!(
        got.remind.as_deref(),
        Some("2026-10-06T18:00"),
        "a field with no standard property arrives through the state"
    );
    assert_eq!(titles(&b.subtasks(top.id).unwrap()), ["зайти в магазин"]);
}

#[test]
fn c16_a_second_run_writes_nothing() {
    let dav = start();
    let (a, b) = pair(&dav);
    add(&a, "задача");
    a.create_list("Работа".into()).unwrap();
    settle(&a, &b);
    b.sync_now().unwrap();
    assert_eq!(a.sync_now().unwrap(), SyncReport::default());
    assert_eq!(b.sync_now().unwrap(), SyncReport::default());
}

#[test]
fn s2_edits_of_different_fields_on_two_devices_are_both_kept() {
    let dav = start();
    let (a, b) = pair(&dav);
    let t = add(&a, "исходное");
    settle(&a, &b);

    a.set_title(t.id.clone(), "новое название".into()).unwrap();
    b.set_due(t.id.clone(), Some("2026-10-09".into())).unwrap();
    // C13: B writes first; A's write is refused, merged and repeated.
    b.sync_now().unwrap();
    a.sync_now().unwrap();
    b.sync_now().unwrap();
    for d in [&a, &b] {
        let got = d.task(t.id.clone()).unwrap();
        assert_eq!(
            (got.title.as_str(), got.due.as_deref()),
            ("новое название", Some("2026-10-09"))
        );
    }
    assert_eq!(a.sync_now().unwrap(), SyncReport::default());
}

#[test]
fn c13_write_refused_by_the_server_is_merged_and_repeated_in_the_same_run() {
    let dav = start();
    let (a, _b) = pair(&dav);
    let t = add(&a, "задача");
    a.sync_now().unwrap();

    // Another client rewrites the object after A has read the calendar and
    // before A's own PUT arrives: the server must answer 412.
    let theirs = dav.read(&t.id).replace("SUMMARY:задача", "SUMMARY:Changed in between");
    std::fs::write(
        dav.root.path().join(".race"),
        format!("cal/lists-inbox/{}.ics\n{theirs}", t.id),
    )
    .unwrap();
    a.set_priority(t.id.clone(), Priority::Medium).unwrap();
    a.sync_now().unwrap();

    assert!(!dav.root.path().join(".race").exists(), "the concurrent write happened");
    let on_server = dav.read(&t.id).replace("\r\n ", "");
    assert!(
        on_server.contains("SUMMARY:Changed in between") && on_server.contains("PRIORITY:5"),
        "{on_server}"
    );
    let got = a.task(t.id).unwrap();
    assert_eq!(
        (got.title.as_str(), got.priority),
        ("Changed in between", Priority::Medium)
    );
    assert_eq!(a.sync_now().unwrap(), SyncReport::default());
}

#[test]
fn c7_c8_another_client_edits_standard_properties_and_adds_its_own() {
    let dav = start();
    let (a, b) = pair(&dav);
    let t = add(&a, "старое название");
    a.set_remind(t.id.clone(), Some("2026-10-06T09:00".into())).unwrap();
    a.add_tag(t.id.clone(), "дом".into()).unwrap();
    settle(&a, &b);

    dav.edit(&t.id, |lines| {
        let mut out: Vec<String> = lines
            .into_iter()
            .map(|l| {
                if l.starts_with("SUMMARY:") {
                    "SUMMARY:Renamed elsewhere".to_string()
                } else {
                    l
                }
            })
            .filter(|l| !l.starts_with("CATEGORIES"))
            .collect();
        let end = out.iter().position(|l| l == "END:VTODO").unwrap();
        out.insert(end, "X-OTHER-CLIENT:keep me".into());
        out.insert(end, "DUE;VALUE=DATE:20261012".into());
        out.insert(end, "PRIORITY:1".into());
        out.insert(end, "CATEGORIES:Office".into());
        out
    });

    assert!(a.sync_now().unwrap().pulled > 0);
    let got = a.task(t.id.clone()).unwrap();
    assert_eq!(got.title, "Renamed elsewhere");
    assert_eq!(got.due.as_deref(), Some("2026-10-12"));
    assert_eq!(got.priority, Priority::High);
    assert_eq!(got.tags, ["office"]);
    assert_eq!(got.remind.as_deref(), Some("2026-10-06T09:00"), "untouched fields stay");

    // A's write-back keeps the other client's property, and B converges.
    a.set_notes(t.id.clone(), "после чужой правки".into()).unwrap();
    a.sync_now().unwrap();
    assert!(dav.read(&t.id).contains("X-OTHER-CLIENT:keep me"));
    b.sync_now().unwrap();
    assert_eq!(b.task(t.id.clone()).unwrap().title, "Renamed elsewhere");
    assert_eq!(b.task(t.id).unwrap().tags, ["office"]);
    a.sync_now().unwrap();
    assert_eq!(a.sync_now().unwrap(), SyncReport::default());
    assert_eq!(b.sync_now().unwrap(), SyncReport::default());
}

#[test]
fn c9_state_removed_by_another_client_is_restored_without_losing_fields() {
    let dav = start();
    let (a, b) = pair(&dav);
    let t = add(&a, "задача");
    a.set_remind(t.id.clone(), Some("2026-10-06T09:00".into())).unwrap();
    settle(&a, &b);

    dav.edit(&t.id, |lines| {
        lines
            .into_iter()
            .filter(|l| !l.starts_with("X-LISTS-STATE"))
            .map(|l| {
                if l.starts_with("SUMMARY:") {
                    "SUMMARY:Stripped and renamed".to_string()
                } else {
                    l
                }
            })
            .collect()
    });
    a.sync_now().unwrap();
    let got = a.task(t.id.clone()).unwrap();
    assert_eq!(got.title, "Stripped and renamed");
    assert_eq!(got.remind.as_deref(), Some("2026-10-06T09:00"));
    assert!(
        dav.read(&t.id).contains("X-LISTS-STATE:"),
        "the state is back on the server"
    );

    b.sync_now().unwrap();
    let got = b.task(t.id).unwrap();
    assert_eq!(
        (got.title.as_str(), got.remind.as_deref()),
        ("Stripped and renamed", Some("2026-10-06T09:00"))
    );
}

#[test]
fn c10_task_created_by_another_client_gets_the_same_identity_everywhere() {
    let dav = start();
    let (a, b) = pair(&dav);
    settle(&a, &b);
    std::fs::write(
        dav.home().join("lists-inbox").join("foreign.ics"),
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Other//EN\r\nBEGIN:VTODO\r\nUID:foreign-uid-1\r\nSUMMARY:From another app\r\nDUE;VALUE=DATE:20261007\r\nPRIORITY:5\r\nEND:VTODO\r\nEND:VCALENDAR\r\n",
    )
    .unwrap();
    settle(&a, &b);
    for d in [&a, &b] {
        let got = d.task("foreign-uid-1".into()).unwrap();
        assert_eq!(
            (got.title.as_str(), got.due.as_deref(), got.priority),
            ("From another app", Some("2026-10-07"), Priority::Medium)
        );
        assert_eq!(got.list_id, INBOX_ID);
        assert_eq!(view(d, Scope::Inbox), ["From another app"]);
    }
    // The object stays under the name the other client gave it: no duplicate appears.
    assert_eq!(dav.objects(), 1);
    b.sync_now().unwrap();
    assert_eq!(a.sync_now().unwrap(), SyncReport::default());
}

#[test]
fn c11_repeating_task_completed_elsewhere_moves_to_the_next_occurrence() {
    let dav = start();
    let (a, b) = pair(&dav);
    let t = add(&a, "зарядка");
    a.set_due(t.id.clone(), Some("2026-10-05".into())).unwrap();
    a.set_repeat(t.id.clone(), Some(daily())).unwrap();
    settle(&a, &b);

    dav.edit(&t.id, |lines| {
        lines
            .into_iter()
            .flat_map(|l| {
                if l.starts_with("STATUS:") {
                    vec!["STATUS:COMPLETED".to_string(), "COMPLETED:20261005T080000Z".to_string()]
                } else {
                    vec![l]
                }
            })
            .collect()
    });
    a.sync_now().unwrap();
    let got = a.task(t.id.clone()).unwrap();
    assert!(got.done.is_none(), "still open");
    assert_eq!(got.due.as_deref(), Some("2026-10-06"));
    assert_eq!(
        view(&a, Scope::Completed),
        ["зарядка"],
        "the finished occurrence is recorded"
    );
    assert!(dav.read(&t.id).contains("STATUS:NEEDS-ACTION"));

    b.sync_now().unwrap();
    assert_eq!(b.task(t.id).unwrap().due.as_deref(), Some("2026-10-06"));
}

#[test]
fn plain_task_completed_and_reopened_elsewhere() {
    let dav = start();
    let (a, _b) = pair(&dav);
    let t = add(&a, "разовая");
    a.sync_now().unwrap();
    dav.edit(&t.id, |lines| {
        lines
            .into_iter()
            .map(|l| {
                if l.starts_with("STATUS:") {
                    "STATUS:COMPLETED".to_string()
                } else {
                    l
                }
            })
            .collect()
    });
    a.sync_now().unwrap();
    assert!(a.task(t.id.clone()).unwrap().done.is_some());

    dav.edit(&t.id, |lines| {
        lines
            .into_iter()
            .filter(|l| !l.starts_with("COMPLETED:") && !l.starts_with("PERCENT-COMPLETE"))
            .map(|l| {
                if l.starts_with("STATUS:") {
                    "STATUS:NEEDS-ACTION".to_string()
                } else {
                    l
                }
            })
            .collect()
    });
    a.sync_now().unwrap();
    assert!(a.task(t.id).unwrap().done.is_none());
}

#[test]
fn c6_c14_trash_removes_the_object_and_a_vanished_object_goes_to_the_trash() {
    let dav = start();
    let (a, b) = pair(&dav);
    let t = add(&a, "удаляемая");
    let kept = add(&a, "остаётся");
    settle(&a, &b);
    assert_eq!(dav.objects(), 2);

    b.set_notes(t.id.clone(), "правка до удаления".into()).unwrap();
    a.delete_task(t.id.clone()).unwrap();
    a.sync_now().unwrap();
    assert_eq!(dav.objects(), 1, "the trashed task has no object");

    b.sync_now().unwrap();
    assert_eq!(view(&b, Scope::Inbox), ["остаётся"]);
    assert_eq!(view(&b, Scope::Trash), ["удаляемая"]);
    assert_eq!(dav.objects(), 1, "B does not put the object back");

    // Restoring brings the object back, with the edit B made before it vanished.
    b.restore_task(t.id.clone()).unwrap();
    b.sync_now().unwrap();
    a.sync_now().unwrap();
    assert_eq!(a.task(t.id.clone()).unwrap().notes, "правка до удаления");
    assert!(!a.task(t.id).unwrap().deleted);

    // Another client deletes an object outright.
    std::fs::remove_file(dav.object(&kept.id)).unwrap();
    settle(&a, &b);
    for d in [&a, &b] {
        assert!(d.task(kept.id.clone()).unwrap().deleted);
    }
}

#[test]
fn c1_c15_lists_are_calendars_with_their_settings() {
    let dav = start();
    let (a, b) = pair(&dav);
    let list = a.create_list("Работа".into()).unwrap();
    a.set_list_color(list.id.clone(), "#FF9500".into()).unwrap();
    a.set_list_sort(list.id.clone(), SortMode::Due).unwrap();
    let t = a
        .create_task(NewTask {
            title: "отчёт".into(),
            list_id: Some(list.id.clone()),
            ..NewTask::default()
        })
        .unwrap();
    settle(&a, &b);

    let props = std::fs::read_to_string(dav.home().join(&list.id).join(".props")).unwrap();
    assert!(
        props.contains("name=Работа") && props.contains("color=#FF9500"),
        "{props}"
    );
    let got = b.list(list.id.clone()).unwrap();
    assert_eq!(
        (got.name.as_str(), got.color.as_str(), got.sort),
        ("Работа", "#FF9500", SortMode::Due)
    );
    assert_eq!(view(&b, Scope::List { id: list.id.clone() }), ["отчёт"]);

    // Another client renames the calendar.
    std::fs::write(
        dav.home().join(&list.id).join(".props"),
        props.replace("name=Работа", "name=Office"),
    )
    .unwrap();
    settle(&b, &a);
    assert_eq!(a.list(list.id.clone()).unwrap().name, "Office");
    assert_eq!(b.list(list.id.clone()).unwrap().name, "Office");

    // Moving a task to another list moves its object to that calendar.
    a.move_to_list(t.id.clone(), INBOX_ID.into()).unwrap();
    settle(&a, &b);
    assert!(dav.object(&t.id).exists() && !dav.home().join(&list.id).join(format!("{}.ics", t.id)).exists());
    assert_eq!(view(&b, Scope::Inbox), ["отчёт"]);

    // Deleting the list removes the calendar once it is empty, and the other device follows.
    a.delete_list(list.id.clone()).unwrap();
    a.sync_now().unwrap();
    assert!(!dav.home().join(&list.id).exists());
    b.sync_now().unwrap();
    assert!(b.list(list.id).is_err());
    assert_eq!(
        view(&b, Scope::Inbox),
        ["отчёт"],
        "tasks that had left the list are untouched"
    );
}

#[test]
fn c1_server_that_drops_custom_properties_still_syncs_names_and_tasks() {
    let dav = start();
    std::fs::write(dav.root.path().join(".no-custom-props"), "").unwrap();
    let (a, b) = pair(&dav);
    let list = a.create_list("Дом".into()).unwrap();
    a.set_list_sort(list.id.clone(), SortMode::Title).unwrap();
    a.create_task(NewTask {
        title: "полить цветы".into(),
        list_id: Some(list.id.clone()),
        ..NewTask::default()
    })
    .unwrap();
    settle(&a, &b);
    let got = b.list(list.id.clone()).unwrap();
    assert_eq!(got.name, "Дом");
    assert_eq!(
        got.sort,
        SortMode::Manual,
        "settings beyond name and colour stay on the device that set them"
    );
    assert_eq!(view(&b, Scope::List { id: list.id }), ["полить цветы"]);
    // The refused property is not sent again and again.
    b.sync_now().unwrap();
    assert_eq!(a.sync_now().unwrap(), SyncReport::default());
}

#[test]
fn calendar_made_by_another_client_becomes_the_same_list_on_every_device() {
    let dav = start();
    let (a, b) = pair(&dav);
    let dir = dav.home().join("personal");
    std::fs::create_dir(&dir).unwrap();
    std::fs::write(dir.join(".props"), "calendar=1\nname=Personal\ncolor=#00FF00FF\n").unwrap();
    std::fs::write(
        dir.join("x.ics"),
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:x-1\r\nSUMMARY:Existing task\r\nEND:VTODO\r\nEND:VCALENDAR\r\n",
    )
    .unwrap();
    settle(&a, &b);
    let find = |d: &Device| {
        d.lists()
            .unwrap()
            .into_iter()
            .find(|l| l.name == "Personal")
            .expect("list")
    };
    let (la, lb) = (find(&a), find(&b));
    assert_eq!(la.id, lb.id);
    assert_eq!(la.color, "#00FF00");
    assert_eq!(view(&a, Scope::List { id: la.id.clone() }), ["Existing task"]);
    assert_eq!(view(&b, Scope::List { id: lb.id }), ["Existing task"]);
}

#[test]
fn c5_attachment_reaches_the_other_device() {
    let dav = start();
    let (a, b) = pair(&dav);
    let t = add(&a, "с файлом");
    let src = tempfile::tempdir().unwrap();
    let file = src.path().join("note.txt");
    std::fs::write(&file, "вложение").unwrap();
    let att = a
        .add_attachment(t.id.clone(), file.to_string_lossy().into_owned(), None)
        .unwrap();

    assert_eq!(a.sync_now().unwrap().blobs_uploaded, 1);
    assert_eq!(b.sync_now().unwrap().blobs_downloaded, 1);
    let got = b.attachments(t.id.clone()).unwrap();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].sha256, att.sha256);
    assert_eq!(
        std::fs::read_to_string(got[0].local_path.as_ref().unwrap()).unwrap(),
        "вложение"
    );

    // Removing it on B takes the content out of the object.
    b.remove_attachment(got[0].id.clone()).unwrap();
    b.sync_now().unwrap();
    assert!(!dav.read(&t.id).contains("ATTACH"));
    a.sync_now().unwrap();
    assert!(a.attachments(t.id).unwrap().is_empty());
}

#[test]
fn wrong_password_and_bad_address_are_reported() {
    let dav = start();
    let a = device();
    connect(&a, &dav);
    a.set_sync_password(Some("wrong".into()));
    add(&a, "ждёт");
    let err = a.sync_now().unwrap_err().to_string();
    assert!(err.contains("401"), "{err}");
    assert!(a
        .set_sync_config(SyncConfig::CalDav {
            url: "example.org/dav".into(),
            user: String::new()
        })
        .is_err());
    a.set_sync_password(Some("secret".into()));
    assert!(a.sync_now().unwrap().pushed > 0);
}

#[test]
fn switching_from_the_log_to_caldav_carries_everything_over() {
    let dav = start();
    let folder = tempfile::tempdir().unwrap();
    let (a, b) = (device(), device());
    a.set_sync_config(SyncConfig::Folder {
        path: folder.path().to_string_lossy().into_owned(),
    })
    .unwrap();
    let t = add(&a, "из журнала");
    add_sub(&a, &t, "подзадача");
    a.sync_now().unwrap();

    connect(&a, &dav);
    a.sync_now().unwrap();
    connect(&b, &dav);
    b.sync_now().unwrap();
    assert_eq!(view(&b, Scope::Inbox), ["из журнала"]);
    assert_eq!(titles(&b.subtasks(t.id).unwrap()), ["подзадача"]);
}

#[test]
fn projects_and_saved_filters_travel_through_caldav() {
    let dav = start();
    let (a, b) = pair(&dav);
    let p = add(&a, "проект");
    a.set_project(p.id.clone(), true).unwrap();
    a.quick_add_under("шаг".into(), p.id.clone()).unwrap();
    a.create_filter(
        "Неделя".into(),
        FilterSpec {
            due: DueWindow::Next { days: 7 },
            ..FilterSpec::default()
        },
    )
    .unwrap();
    settle(&a, &b);

    assert_eq!(titles(&b.projects().unwrap()), ["проект"]);
    assert_eq!(view(&b, Scope::Project { id: p.id }), ["шаг"]);
    let filters = b.filters().unwrap();
    assert_eq!((filters.len(), filters[0].name.as_str()), (1, "Неделя"));

    b.delete_filter(filters[0].id.clone()).unwrap();
    settle(&b, &a);
    assert!(a.filters().unwrap().is_empty());
    a.sync_now().unwrap();
    assert_eq!(b.sync_now().unwrap(), SyncReport::default());
}
