//! The web server over HTTP: login, the session cookie, and a task's life
//! through the JSON interface.

use lists_core::{Store, SyncConfig};
use lists_web::{start, Config};
use serde_json::{json, Value};

struct Web {
    base: String,
    _dir: tempfile::TempDir,
}

fn web(password: Option<&str>) -> Web {
    web_syncing(password, SyncConfig::Off)
}

fn web_syncing(password: Option<&str>, sync: SyncConfig) -> Web {
    let dir = tempfile::tempdir().unwrap();
    let running = start(Config {
        data_dir: dir.path().to_string_lossy().into_owned(),
        listen: "127.0.0.1:0".into(),
        password: password.map(str::to_string),
        oidc: None,
        sync,
        sync_password: None,
        push_server: None,
        push_token: None,
    })
    .unwrap();
    Web {
        base: format!("http://{}", running.addr),
        _dir: dir,
    }
}

fn status(result: Result<ureq::Response, ureq::Error>) -> u16 {
    match result {
        Ok(r) => r.status(),
        Err(ureq::Error::Status(code, _)) => code,
        Err(e) => panic!("{e}"),
    }
}

fn login(web: &Web, password: &str) -> Option<String> {
    let response = ureq::post(&format!("{}/api/login", web.base))
        .send_json(json!({ "password": password }))
        .ok()?;
    let cookie = response.header("Set-Cookie")?.split(';').next()?.to_string();
    assert!(
        response.header("Set-Cookie").unwrap().contains("HttpOnly")
            && response.header("Set-Cookie").unwrap().contains("SameSite=Strict")
    );
    Some(cookie)
}

fn call(web: &Web, cookie: &str, body: Value) -> Value {
    ureq::post(&format!("{}/api/call", web.base))
        .set("Cookie", cookie)
        .set("X-Lists", "1")
        .send_json(body)
        .unwrap()
        .into_json()
        .unwrap()
}

fn get(web: &Web, cookie: &str, path: &str) -> Value {
    ureq::get(&format!("{}{path}", web.base))
        .set("Cookie", cookie)
        .call()
        .unwrap()
        .into_json()
        .unwrap()
}

#[test]
fn nothing_is_served_without_a_session() {
    let web = web(Some("secret"));
    assert_eq!(
        status(ureq::get(&format!("{}/", web.base)).call()),
        200,
        "the page itself is public"
    );
    assert_eq!(status(ureq::get(&format!("{}/api/overview", web.base)).call()), 401);
    assert_eq!(
        status(ureq::get(&format!("{}/api/tasks?scope=inbox", web.base)).call()),
        401
    );
    assert_eq!(
        status(
            ureq::post(&format!("{}/api/call", web.base))
                .set("X-Lists", "1")
                .send_json(json!({ "op": "emptyTrash" }))
        ),
        401
    );
    assert!(login(&web, "wrong").is_none());
    assert_eq!(
        status(
            ureq::get(&format!("{}/api/overview", web.base))
                .set("Cookie", "lists_session=guess")
                .call()
        ),
        401
    );

    let cookie = login(&web, "secret").unwrap();
    assert_eq!(
        status(
            ureq::get(&format!("{}/api/overview", web.base))
                .set("Cookie", &cookie)
                .call()
        ),
        200
    );
    // A cross-site form can send the cookie-less POST but not the header.
    assert_eq!(
        status(
            ureq::post(&format!("{}/api/call", web.base))
                .set("Cookie", &cookie)
                .send_json(json!({ "op": "emptyTrash" }))
        ),
        400
    );

    assert_eq!(
        status(
            ureq::post(&format!("{}/api/logout", web.base))
                .set("Cookie", &cookie)
                .set("X-Lists", "1")
                .call()
        ),
        200
    );
    assert_eq!(
        status(
            ureq::get(&format!("{}/api/overview", web.base))
                .set("Cookie", &cookie)
                .call()
        ),
        401,
        "the session is gone"
    );
}

#[test]
fn a_task_from_quick_entry_to_the_trash() {
    let web = web(Some("secret"));
    let cookie = login(&web, "secret").unwrap();

    let list = call(&web, &cookie, json!({ "op": "createList", "name": "Работа" }));
    let scope = format!("list:{}", list["id"].as_str().unwrap());
    let task = call(
        &web,
        &cookie,
        json!({ "op": "quickAdd", "text": "отчёт завтра 10:00 !! #квартал", "scope": scope }),
    );
    let id = task["id"].as_str().unwrap().to_string();
    assert_eq!(task["title"], "отчёт");
    assert_eq!(task["priority"], 2);
    assert_eq!(task["tags"], json!(["квартал"]));
    assert!(task["due"].as_str().unwrap().ends_with("T10:00"));

    call(
        &web,
        &cookie,
        json!({ "op": "setNotes", "id": id, "value": "черновик готов" }),
    );
    call(
        &web,
        &cookie,
        json!({ "op": "setRepeat", "id": id, "value": { "freq": "weekly", "interval": 1 } }),
    );
    call(
        &web,
        &cookie,
        json!({ "op": "addSubtask", "parent": id, "title": "собрать цифры" }),
    );
    let detail = get(&web, &cookie, &format!("/api/task?id={id}"));
    assert_eq!(detail["task"]["notes"], "черновик готов");
    assert_eq!(detail["task"]["repeat"]["freq"], "weekly");
    assert_eq!(detail["subtasks"][0]["title"], "собрать цифры");

    let listed = get(
        &web,
        &cookie,
        &format!("/api/tasks?scope={}", scope.replace(':', "%3A")),
    );
    assert_eq!(listed.as_array().unwrap().len(), 1);
    let overview = get(&web, &cookie, "/api/overview");
    assert_eq!(overview["lists"][1]["name"], "Работа");
    assert_eq!(overview["lists"][1]["open"], 1);
    assert_eq!(overview["tags"][0]["name"], "квартал");

    // R75: the view gives a new task neither a date nor a tag.
    let quick = call(
        &web,
        &cookie,
        json!({ "op": "quickAdd", "text": "позвонить", "scope": "today" }),
    );
    assert!(quick["due"].is_null());

    call(&web, &cookie, json!({ "op": "delete", "id": id }));
    assert_eq!(
        get(&web, &cookie, "/api/tasks?scope=trash").as_array().unwrap().len(),
        1
    );
    assert_eq!(call(&web, &cookie, json!({ "op": "emptyTrash" }))["removed"], 1);
    let tagged = call(
        &web,
        &cookie,
        json!({ "op": "quickAdd", "text": "написать", "scope": "tag:квартал" }),
    );
    assert_eq!(tagged["tags"], json!([]));
    call(&web, &cookie, json!({ "op": "delete", "id": tagged["id"] }));
    assert_eq!(call(&web, &cookie, json!({ "op": "emptyTrash" }))["removed"], 1);

    let completed = |web: &Web| {
        get(web, &cookie, "/api/tasks?scope=completed")
            .as_array()
            .unwrap()
            .len()
    };
    let finished = call(&web, &cookie, json!({ "op": "quickAdd", "text": "сделано" }));
    call(&web, &cookie, json!({ "op": "complete", "id": finished["id"] }));
    let done_on = get(&web, &cookie, "/api/tasks?scope=completed")[0]["done"]
        .as_str()
        .unwrap()[..10]
        .to_string();
    assert_eq!(
        call(&web, &cookie, json!({ "op": "clearCompleted", "before": done_on }))["removed"],
        0,
        "nothing was completed before that day"
    );
    assert_eq!(completed(&web), 1);
    assert_eq!(call(&web, &cookie, json!({ "op": "clearCompleted" }))["removed"], 1);
    assert_eq!(completed(&web), 0);

    let bad = ureq::post(&format!("{}/api/call", web.base))
        .set("Cookie", &cookie)
        .set("X-Lists", "1")
        .send_json(json!({ "op": "noSuchThing" }));
    assert_eq!(status(bad), 400);
    assert_eq!(
        status(
            ureq::get(&format!("{}/api/tasks?scope=bogus", web.base))
                .set("Cookie", &cookie)
                .call()
        ),
        400
    );
}

#[test]
fn r53_a_note_comes_with_the_ranges_to_show_it_as_markdown() {
    let web = web(Some("secret"));
    let cookie = login(&web, "secret").unwrap();
    let task = call(
        &web,
        &cookie,
        json!({ "op": "quickAdd", "text": "заметка", "scope": "inbox" }),
    );
    let id = task["id"].as_str().unwrap().to_string();
    let notes = "😀 **да** [x](javascript:alert(1)) [сайт](https://example.org)\n- [x] хлеб";
    call(&web, &cookie, json!({ "op": "setNotes", "id": id, "value": notes }));

    let detail = get(&web, &cookie, &format!("/api/task?id={id}"));
    // The note itself is served as it was typed.
    assert_eq!(detail["task"]["notes"], notes);
    let spans = detail["markdown"].as_array().unwrap();
    let of = |kind: &str| spans.iter().filter(|s| s[2] == kind).cloned().collect::<Vec<_>>();
    // Offsets count UTF-16 units, the way the page indexes the text.
    assert_eq!(of("strong"), [json!([5, 7, "strong", null])]);
    assert_eq!(of("checkbox"), [json!([65, 68, "checkbox", true])]);
    // Only a web or a mail address is ever a link.
    assert_eq!(of("link"), [json!([36, 40, "link", "https://example.org"])]);
}

#[test]
fn r60_a_table_comes_with_its_cells() {
    let web = web(None);
    let task = call(
        &web,
        "",
        json!({ "op": "quickAdd", "text": "таблица", "scope": "inbox" }),
    );
    let id = task["id"].as_str().unwrap().to_string();
    let notes = "😀 | б\n:-: | --:\n**1** | 2";
    call(&web, "", json!({ "op": "setNotes", "id": id, "value": notes }));

    let detail = get(&web, "", &format!("/api/task?id={id}"));
    assert_eq!(detail["task"]["notes"], notes);
    // Offsets count UTF-16 units; the line of dashes is not among the rows.
    assert_eq!(
        detail["tables"],
        json!([{
            "start": 0, "end": 26, "columns": ["center", "right"],
            "rows": [
                { "header": true, "cells": [[0, 2], [5, 6]] },
                { "header": false, "cells": [[17, 22], [25, 26]] },
            ],
        }])
    );
}

#[test]
fn attachments_upload_and_download_as_files() {
    let web = web(None);
    let task = call(&web, "", json!({ "op": "quickAdd", "text": "с файлом" }));
    let id = task["id"].as_str().unwrap();
    let uploaded: Value = ureq::post(&format!("{}/api/upload?task={id}&name=page.html", web.base))
        .set("X-Lists", "1")
        .send_bytes(b"<script>alert(1)</script>")
        .unwrap()
        .into_json()
        .unwrap();
    assert_eq!(uploaded["name"], "page.html");

    let file = ureq::get(&format!(
        "{}/api/file?task={id}&id={}",
        web.base,
        uploaded["id"].as_str().unwrap()
    ))
    .call()
    .unwrap();
    // Served as a download, never as a page of this origin.
    assert_eq!(file.header("Content-Type"), Some("application/octet-stream"));
    assert!(file.header("Content-Disposition").unwrap().starts_with("attachment"));
    assert_eq!(file.header("X-Content-Type-Options"), Some("nosniff"));
    assert_eq!(file.into_string().unwrap(), "<script>alert(1)</script>");
}

#[test]
fn r76_a_waiting_attachment_is_fetched_when_it_is_asked_for() {
    let storage = tempfile::tempdir().unwrap();
    let folder = SyncConfig::Folder {
        path: storage.path().to_string_lossy().into_owned(),
    };
    let web = web_syncing(None, folder.clone());

    // Another device attaches a file; only the fields have reached the storage.
    let (data, source) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let other = Store::open(data.path().to_string_lossy().into_owned()).unwrap();
    other.set_sync_config(folder).unwrap();
    let task = other.quick_add("с файлом".into(), None).unwrap();
    let file = source.path().join("note.txt");
    std::fs::write(&file, b"from the other device").unwrap();
    let added = other
        .add_attachment(task.id.clone(), file.to_string_lossy().into_owned(), None)
        .unwrap();
    other.sync_now().unwrap();

    call(&web, "", json!({ "op": "sync" }));
    let path = format!("/api/task?id={}", task.id);
    let listed = get(&web, "", &path);
    assert_eq!(listed["attachments"][0]["name"], "note.txt");
    assert_eq!(listed["attachments"][0]["present"], false);
    assert_eq!(get(&web, "", "/api/overview")["sync"]["attachmentsWaiting"], 1);

    // The content is not in the storage: the answer is an error with a reason, and the file still waits.
    let url = format!("{}/api/file?task={}&id={}", web.base, task.id, added.id);
    match ureq::get(&url).call() {
        Err(ureq::Error::Status(502, response)) => {
            let body: Value = response.into_json().unwrap();
            assert!(body["error"].as_str().unwrap().contains("storage"), "{body}");
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(get(&web, "", &path)["attachments"][0]["present"], false);

    // It is there now: the same request brings the file, ahead of the server's own pass.
    other.sync_attachments().unwrap();
    let got = ureq::get(&url).call().unwrap();
    assert!(got.header("Content-Disposition").unwrap().starts_with("attachment"));
    assert_eq!(got.into_string().unwrap(), "from the other device");
    assert_eq!(get(&web, "", &path)["attachments"][0]["present"], true);
    assert_eq!(get(&web, "", "/api/overview")["sync"]["attachmentsWaiting"], 0);

    // An attachment that does not exist is not looked for in the storage.
    let missing = format!("{}/api/file?task={}&id=nothing", web.base, task.id);
    assert_eq!(status(ureq::get(&missing).call()), 404);
}

fn upload(web: &Web, task: &str, name: &str, data: &[u8]) -> Value {
    ureq::post(&format!("{}/api/upload?task={task}&name={name}", web.base))
        .set("X-Lists", "1")
        .send_bytes(data)
        .unwrap()
        .into_json()
        .unwrap()
}

#[test]
fn r56_only_listed_types_are_shown_in_place() {
    let web = web(None);
    let task = call(&web, "", json!({ "op": "quickAdd", "text": "с картинкой" }));
    let id = task["id"].as_str().unwrap();
    let file = |a: &Value, view: bool| {
        ureq::get(&format!(
            "{}/api/file?task={id}&id={}{}",
            web.base,
            a["id"].as_str().unwrap(),
            if view { "&view=1" } else { "" }
        ))
        .call()
        .unwrap()
    };

    for (name, mime, kind) in [
        ("photo.png", "image/png", "image"),
        ("photo.JPG", "image/jpeg", "image"),
        ("anim.gif", "image/gif", "image"),
        ("pic.webp", "image/webp", "image"),
        ("paper.pdf", "application/pdf", "pdf"),
    ] {
        let a = upload(&web, id, name, b"content");
        assert_eq!(a["preview"], kind, "{name}");
        let shown = file(&a, true);
        assert_eq!(shown.header("Content-Type"), Some(mime), "{name}");
        assert!(
            shown.header("Content-Disposition").unwrap().starts_with("inline"),
            "{name}"
        );
        assert_eq!(shown.header("X-Content-Type-Options"), Some("nosniff"), "{name}");
        let policy = shown.header("Content-Security-Policy").unwrap();
        assert!(policy.contains("default-src 'none'"), "{name}: {policy}");
        // Without the request to show it, the same file is a download.
        let saved = file(&a, false);
        assert_eq!(saved.header("Content-Type"), Some("application/octet-stream"), "{name}");
        assert!(
            saved.header("Content-Disposition").unwrap().starts_with("attachment"),
            "{name}"
        );
    }
    let image = upload(&web, id, "safe.png", b"content");
    assert!(file(&image, true)
        .header("Content-Security-Policy")
        .unwrap()
        .contains("sandbox"));

    // What can carry a script is downloaded even when the page asks to show it.
    for name in [
        "page.html",
        "page.htm",
        "drawing.svg",
        "notes.txt",
        "photo.heic",
        "archive.zip",
        "noext",
    ] {
        let a = upload(&web, id, name, b"<script>alert(1)</script>");
        assert_eq!(a["preview"], Value::Null, "{name}");
        let got = file(&a, true);
        assert_eq!(got.header("Content-Type"), Some("application/octet-stream"), "{name}");
        assert!(
            got.header("Content-Disposition").unwrap().starts_with("attachment"),
            "{name}"
        );
        assert_eq!(got.header("Content-Security-Policy"), None, "{name}");
    }
}

#[test]
fn r126_a_project_is_completed_from_the_sidebar_and_comes_back_on_undo() {
    let web = web(None);
    let project = call(&web, "", json!({ "op": "quickAdd", "text": "Переезд" }));
    let id = project["id"].as_str().unwrap().to_string();
    call(&web, "", json!({ "op": "setProject", "id": id, "value": true }));
    let scope = format!("project:{id}");
    let open = call(&web, "", json!({ "op": "quickAdd", "text": "Коробки", "scope": scope }));
    let done = call(&web, "", json!({ "op": "quickAdd", "text": "Грузчики", "scope": scope }));
    call(&web, "", json!({ "op": "complete", "id": done["id"] }));

    call(&web, "", json!({ "op": "complete", "id": id }));
    let overview = get(&web, "", "/api/overview");
    assert_eq!(overview["projects"].as_array().unwrap().len(), 0, "it leaves the sidebar (R32)");
    let task = get(&web, "", &format!("/api/task?id={}", open["id"].as_str().unwrap()));
    assert!(!task["task"]["done"].is_null(), "its open task is completed with it (R11)");

    call(&web, "", json!({ "op": "undoClose", "id": id }));
    let overview = get(&web, "", "/api/overview");
    assert_eq!(overview["projects"][0]["title"], "Переезд");
    assert_eq!(overview["projects"][0]["subtasks"], 2);
    assert_eq!(overview["projects"][0]["subtasksDone"], 1, "the task completed before stays completed");
}

#[test]
fn projects_and_saved_filters_over_the_api() {
    let web = web(None);
    let project = call(&web, "", json!({ "op": "quickAdd", "text": "Запуск сайта" }));
    let id = project["id"].as_str().unwrap().to_string();
    call(&web, "", json!({ "op": "setProject", "id": id, "value": true }));
    let step = call(
        &web,
        "",
        json!({ "op": "quickAdd", "text": "Макеты завтра !!", "scope": format!("project:{id}") }),
    );
    assert_eq!(step["parent"], id.as_str());
    assert_eq!(step["priority"], 2);

    let overview = get(&web, "", "/api/overview");
    assert_eq!(overview["projects"][0]["title"], "Запуск сайта");
    assert_eq!(overview["projects"][0]["subtasks"], 1);
    let inside = get(&web, "", &format!("/api/tasks?scope=project%3A{id}"));
    assert_eq!(inside[0]["title"], "Макеты");

    let made = call(
        &web,
        "",
        json!({ "op": "createFilter", "name": "Важное на неделе", "spec": { "due": { "kind": "next", "days": 7 }, "min_priority": "medium" } }),
    );
    let fid = made["id"].as_str().unwrap().to_string();
    let overview = get(&web, "", "/api/overview");
    assert_eq!(overview["filters"][0]["name"], "Важное на неделе");
    assert_eq!(overview["filters"][0]["open"], 1);
    assert_eq!(overview["filters"][0]["spec"]["due"]["days"], 7);
    assert_eq!(
        get(&web, "", &format!("/api/tasks?scope=filter%3A{fid}"))[0]["title"],
        "Макеты"
    );

    call(&web, "", json!({ "op": "quickAdd", "text": "Черновик" }));
    call(
        &web,
        "",
        json!({ "op": "updateFilter", "id": fid, "name": "Без даты", "spec": { "due": { "kind": "nodate" } } }),
    );
    // The project has no date either, but it is not a row of a filter (R120).
    let dateless = get(&web, "", &format!("/api/tasks?scope=filter%3A{fid}"));
    assert_eq!(dateless.as_array().unwrap().len(), 1);
    assert_eq!(dateless[0]["title"], "Черновик");
    let bad = ureq::post(&format!("{}/api/call", web.base))
        .set("X-Lists", "1")
        .send_json(json!({ "op": "createFilter", "name": "x", "spec": { "due": { "kind": "someday" } } }));
    assert_eq!(status(bad), 400);
    call(&web, "", json!({ "op": "deleteFilter", "id": fid }));
    assert_eq!(get(&web, "", "/api/overview")["filters"].as_array().unwrap().len(), 0);
}

#[test]
fn import_through_the_web() {
    let web = web(None);
    let board = r#"{"name":"B","lists":[{"id":"l1","name":"Do","closed":false}],"cards":[{"id":"c1","name":"Card","desc":"","closed":false,"idList":"l1","idLabels":[]}],"labels":[],"checklists":[]}"#;
    let report: Value = ureq::post(&format!("{}/api/import?name=board.json", web.base))
        .set("X-Lists", "1")
        .send_string(board)
        .unwrap()
        .into_json()
        .unwrap();
    assert_eq!(
        (
            report["source"].as_str(),
            report["lists"].as_u64(),
            report["tasks"].as_u64()
        ),
        (Some("Trello"), Some(1), Some(1))
    );
    assert_eq!(get(&web, "", "/api/overview")["lists"][1]["name"], "B: Do");
    let bad = ureq::post(&format!("{}/api/import?name=x.csv", web.base))
        .set("X-Lists", "1")
        .send_string("a,b\n");
    assert_eq!(status(bad), 400);
}

#[test]
fn icons_are_served_before_login() {
    // The browser asks for them on the login page, and iOS when the page is
    // put on the home screen; none of that carries a session.
    let web = web(Some("secret"));
    for (path, kind, magic) in [
        ("/icon.svg", "image/svg+xml", &b"<svg"[..]),
        ("/icon-32.png", "image/png", &b"\x89PNG"[..]),
        ("/favicon.ico", "image/png", &b"\x89PNG"[..]),
        ("/icon-180.png", "image/png", &b"\x89PNG"[..]),
        ("/apple-touch-icon.png", "image/png", &b"\x89PNG"[..]),
        ("/icon-192.png", "image/png", &b"\x89PNG"[..]),
        ("/icon-512.png", "image/png", &b"\x89PNG"[..]),
    ] {
        let response = ureq::get(&format!("{}{path}", web.base)).call().unwrap();
        assert_eq!(response.content_type(), kind, "{path}");
        let mut body = Vec::new();
        std::io::Read::read_to_end(&mut response.into_reader(), &mut body).unwrap();
        assert!(body.starts_with(magic), "{path}");
    }
    let manifest: Value = ureq::get(&format!("{}/manifest.json", web.base))
        .call()
        .unwrap()
        .into_json()
        .unwrap();
    for icon in manifest["icons"].as_array().unwrap() {
        let src = icon["src"].as_str().unwrap();
        assert_eq!(status(ureq::get(&format!("{}{src}", web.base)).call()), 200, "{src}");
    }
}

#[test]
fn a_completed_task_stays_in_view_until_the_setting_says_otherwise() {
    let web = web(Some("secret"));
    let cookie = login(&web, "secret").unwrap();
    assert_eq!(get(&web, &cookie, "/api/overview")["keepDone"], 5, "seconds");

    let task = call(
        &web,
        &cookie,
        json!({ "op": "quickAdd", "text": "полить цветы", "scope": "inbox" }),
    );
    call(&web, &cookie, json!({ "op": "complete", "id": task["id"] }));
    let inbox = get(&web, &cookie, "/api/tasks?scope=inbox");
    assert_eq!(inbox.as_array().unwrap().len(), 1, "R68: still in its view");
    assert!(inbox[0]["done"].is_string());
    let overview = get(&web, &cookie, "/api/overview");
    assert_eq!(overview["counts"]["inbox"], 0);
    let left = overview["keptFor"]
        .as_u64()
        .expect("the page is told when to look again");
    assert!((1..=6).contains(&left), "within the five seconds: {left}");

    call(&web, &cookie, json!({ "op": "setKeepDone", "value": "day" }));
    let overview = get(&web, &cookie, "/api/overview");
    assert_eq!(overview["keepDone"], "day");
    assert!(overview["keptFor"].as_u64().is_some_and(|left| left <= 86_400));
    assert_eq!(
        get(&web, &cookie, "/api/tasks?scope=inbox").as_array().unwrap().len(),
        1,
        "completed today: still in its view"
    );
    call(&web, &cookie, json!({ "op": "setKeepDone", "value": 15 }));
    assert_eq!(get(&web, &cookie, "/api/overview")["keepDone"], 15);

    call(&web, &cookie, json!({ "op": "setKeepDone", "value": 0 }));
    let overview = get(&web, &cookie, "/api/overview");
    assert_eq!(overview["keepDone"], 0);
    assert!(overview["keptFor"].is_null());
    assert!(get(&web, &cookie, "/api/tasks?scope=inbox")
        .as_array()
        .unwrap()
        .is_empty());
}

#[test]
fn r69_a_task_is_closed_as_wont_do_and_listed_in_its_view() {
    let web = web(Some("secret"));
    let cookie = login(&web, "secret").unwrap();
    call(&web, &cookie, json!({ "op": "setKeepDone", "value": 0 }));
    let add = |text: &str| {
        call(
            &web,
            &cookie,
            json!({ "op": "quickAdd", "text": text, "scope": "inbox" }),
        )
    };
    let (done, wont) = (add("выполнена"), add("не буду"));
    call(&web, &cookie, json!({ "op": "complete", "id": done["id"] }));
    let closed = call(&web, &cookie, json!({ "op": "wontDo", "id": wont["id"] }));
    assert_eq!(closed["wont"], true);
    assert!(closed["done"].is_string());

    let titles = |scope: &str| -> Vec<String> {
        get(&web, &cookie, &format!("/api/tasks?scope={scope}"))
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["title"].as_str().unwrap().to_string())
            .collect()
    };
    assert!(titles("inbox").is_empty());
    assert_eq!(titles("wontdo"), ["не буду"]);
    assert_eq!(titles("completed").len(), 2, "the log holds both outcomes");

    call(&web, &cookie, json!({ "op": "reopen", "id": wont["id"] }));
    assert_eq!(titles("inbox"), ["не буду"]);
    assert!(titles("wontdo").is_empty());
    let back = get(&web, &cookie, "/api/tasks?scope=inbox");
    assert_eq!(back[0]["wont"], false);
}

#[test]
fn r69_r11_undo_brings_back_the_subtasks_closed_with_the_task() {
    let web = web(Some("secret"));
    let cookie = login(&web, "secret").unwrap();
    let top = call(
        &web,
        &cookie,
        json!({ "op": "quickAdd", "text": "родитель", "scope": "inbox" }),
    );
    call(
        &web,
        &cookie,
        json!({ "op": "addSubtask", "parent": top["id"], "title": "подзадача" }),
    );
    let subtask = || {
        let id = top["id"].as_str().unwrap();
        get(&web, &cookie, &format!("/api/task?id={id}"))["subtasks"][0].clone()
    };

    call(&web, &cookie, json!({ "op": "wontDo", "id": top["id"] }));
    assert_eq!(subtask()["wont"], true);

    call(&web, &cookie, json!({ "op": "undoClose", "id": top["id"] }));
    assert!(subtask()["done"].is_null());
    assert_eq!(subtask()["wont"], false);
    let inbox = get(&web, &cookie, "/api/tasks?scope=inbox");
    assert!(inbox[0]["done"].is_null());
}

/// A call the server is expected to refuse: the status of the answer.
fn refused(web: &Web, body: Value) -> u16 {
    status(
        ureq::post(&format!("{}/api/call", web.base))
            .set("X-Lists", "1")
            .send_json(body),
    )
}

#[test]
fn r10_a_due_date_on_a_subtask_is_refused() {
    let web = web(None);
    let top = call(&web, "", json!({ "op": "quickAdd", "text": "а", "scope": "inbox" }));
    let sub = call(
        &web,
        "",
        json!({ "op": "addSubtask", "parent": top["id"], "title": "б" }),
    );
    assert_eq!(
        refused(&web, json!({ "op": "setDue", "id": sub["id"], "value": "2030-01-01" })),
        400
    );
    let id = top["id"].as_str().unwrap();
    let kept = get(&web, "", &format!("/api/task?id={id}"))["subtasks"][0].clone();
    assert_eq!(kept["title"], "б");
    assert!(kept["due"].is_null());

    // What a subtask does have: a title that changes and a mark.
    call(&web, "", json!({ "op": "setTitle", "id": sub["id"], "value": "в" }));
    call(&web, "", json!({ "op": "complete", "id": sub["id"] }));
    let kept = get(&web, "", &format!("/api/task?id={id}"))["subtasks"][0].clone();
    assert_eq!(kept["title"], "в");
    assert!(kept["done"].is_string());
}

#[test]
fn r10_a_subtask_under_a_subtask_is_refused() {
    let web = web(None);
    let top = call(&web, "", json!({ "op": "quickAdd", "text": "а", "scope": "inbox" }));
    let sub = call(
        &web,
        "",
        json!({ "op": "addSubtask", "parent": top["id"], "title": "б" }),
    );
    assert_eq!(
        refused(&web, json!({ "op": "addSubtask", "parent": sub["id"], "title": "в" })),
        400
    );
    let under = |id: &Value| {
        let id = id.as_str().unwrap();
        get(&web, "", &format!("/api/task?id={id}"))["subtasks"]
            .as_array()
            .unwrap()
            .len()
    };
    assert_eq!(under(&sub["id"]), 0);
    assert_eq!(under(&top["id"]), 1);
}

#[test]
fn r10_a_task_of_a_project_keeps_its_due_date() {
    let web = web(None);
    let project = call(&web, "", json!({ "op": "quickAdd", "text": "п", "scope": "inbox" }));
    let id = project["id"].as_str().unwrap().to_string();
    call(&web, "", json!({ "op": "setProject", "id": id, "value": true }));
    let task = call(&web, "", json!({ "op": "addSubtask", "parent": id, "title": "т" }));
    call(
        &web,
        "",
        json!({ "op": "setDue", "id": task["id"], "value": "2030-01-01" }),
    );
    let inside = get(&web, "", &format!("/api/tasks?scope=project%3A{id}"));
    assert_eq!(inside[0]["title"], "т");
    assert_eq!(inside[0]["due"], "2030-01-01");

    // A subtask of that task is a subtask like any other.
    let sub = call(
        &web,
        "",
        json!({ "op": "addSubtask", "parent": task["id"], "title": "у" }),
    );
    assert_eq!(
        refused(&web, json!({ "op": "setDue", "id": sub["id"], "value": "2030-01-01" })),
        400
    );
    // R32: a project that has tasks is not turned back into a task.
    assert_eq!(
        refused(&web, json!({ "op": "setProject", "id": id, "value": false })),
        400
    );
    assert_eq!(get(&web, "", "/api/overview")["projects"][0]["title"], "п");
}

#[test]
fn r22_a_search_shows_the_task_with_the_subtasks_it_was_found_by() {
    let web = web(None);
    let top = call(
        &web,
        "",
        json!({ "op": "quickAdd", "text": "купить", "scope": "inbox" }),
    );
    for title in ["молоко", "хлеб"] {
        call(
            &web,
            "",
            json!({ "op": "addSubtask", "parent": top["id"], "title": title }),
        );
    }
    // "молоко", percent-encoded as the page sends it.
    let found = get(
        &web,
        "",
        "/api/tasks?scope=search%3A%D0%BC%D0%BE%D0%BB%D0%BE%D0%BA%D0%BE",
    );
    let rows = found.as_array().unwrap();
    assert_eq!(rows.len(), 1, "the subtask is not a row of its own");
    assert_eq!(rows[0]["title"], "купить");
    let lines = rows[0]["found"].as_array().unwrap();
    assert_eq!(lines.len(), 1);
    assert_eq!(lines[0]["title"], "молоко");
    assert!(lines[0]["done"].is_null());
    assert_eq!(lines[0]["wont"], false);

    // Found by its own title, the task lists no subtasks; outside a search there is no such field.
    let own = get(
        &web,
        "",
        "/api/tasks?scope=search%3A%D0%BA%D1%83%D0%BF%D0%B8%D1%82%D1%8C",
    );
    assert_eq!(own[0]["found"], json!([]));
    assert!(get(&web, "", "/api/tasks?scope=inbox")[0].get("found").is_none());
}

#[test]
fn r118_a_batch_changes_every_task_it_applies_to_and_is_taken_back_in_one_step() {
    let web = web(Some("secret"));
    let cookie = login(&web, "secret").unwrap();
    let add = |text: &str| {
        call(
            &web,
            &cookie,
            json!({ "op": "quickAdd", "text": text, "scope": "inbox" }),
        )["id"]
            .as_str()
            .unwrap()
            .to_string()
    };
    let task = |id: &str| get(&web, &cookie, &format!("/api/task?id={id}"))["task"].clone();
    let (a, b, c) = (add("альфа !"), add("бета"), add("гамма сегодня"));
    let ids = json!([a, b, c]);

    // A priority: the task that has it already is passed over, and each gets its own back.
    call(&web, &cookie, json!({ "op": "setPriority", "id": b, "value": 3 }));
    let done = call(
        &web,
        &cookie,
        json!({ "op": "batch", "action": "priority", "value": 3, "ids": ids }),
    );
    assert_eq!(done["changed"], 2);
    assert_eq!(task(&a)["priority"], 3);
    call(&web, &cookie, json!({ "op": "batchBack", "steps": done["backs"] }));
    assert_eq!(task(&a)["priority"], 1, "the former priority is back");
    assert_eq!(task(&b)["priority"], 3, "the task that was passed over is as it was");
    assert_eq!(task(&c)["priority"], 0);

    // A tag is stored the way the core stores it, and a date goes to all.
    let tagged = call(
        &web,
        &cookie,
        json!({ "op": "batch", "action": "tag", "value": "#Дом", "ids": ids }),
    );
    assert_eq!(tagged["changed"], 3);
    assert_eq!(task(&b)["tags"], json!(["дом"]));
    call(&web, &cookie, json!({ "op": "batchBack", "steps": tagged["backs"] }));
    assert_eq!(task(&b)["tags"], json!([]));
    let due = task(&c)["due"].clone();
    let dated = call(
        &web,
        &cookie,
        json!({ "op": "batch", "action": "due", "value": "2031-01-02", "ids": ids }),
    );
    assert_eq!(dated["changed"], 3);
    call(&web, &cookie, json!({ "op": "batchBack", "steps": dated["backs"] }));
    assert_eq!(task(&c)["due"], due);
    assert_eq!(task(&a)["due"], Value::Null);

    // A move and its way back; a task that is in the list already is passed over.
    let list = call(&web, &cookie, json!({ "op": "createList", "name": "Работа" }))["id"].clone();
    call(&web, &cookie, json!({ "op": "moveToList", "id": a, "list": list }));
    let moved = call(
        &web,
        &cookie,
        json!({ "op": "batch", "action": "move", "value": list, "ids": ids }),
    );
    assert_eq!(moved["changed"], 2);
    call(&web, &cookie, json!({ "op": "batchBack", "steps": moved["backs"] }));
    assert_eq!(task(&b)["list"], "inbox");
    assert_eq!(task(&a)["list"], list);

    // Completing passes a closed task over; one step reopens the rest.
    call(&web, &cookie, json!({ "op": "complete", "id": a }));
    let closed = call(
        &web,
        &cookie,
        json!({ "op": "batch", "action": "complete", "ids": ids }),
    );
    assert_eq!(closed["changed"], 2);
    call(&web, &cookie, json!({ "op": "batchBack", "steps": closed["backs"] }));
    assert_eq!(task(&b)["done"], Value::Null);
    assert_ne!(
        task(&a)["done"],
        Value::Null,
        "the task closed before the batch stays closed"
    );

    // The trash: nothing but restoring applies there, and its undo puts the tasks back.
    let deleted = call(&web, &cookie, json!({ "op": "batch", "action": "delete", "ids": ids }));
    assert_eq!(deleted["changed"], 3);
    assert_eq!(
        get(&web, &cookie, "/api/tasks?scope=trash").as_array().unwrap().len(),
        3
    );
    let nothing = call(
        &web,
        &cookie,
        json!({ "op": "batch", "action": "complete", "ids": ids }),
    );
    assert_eq!(nothing["changed"], 0);
    let restored = call(&web, &cookie, json!({ "op": "batch", "action": "restore", "ids": ids }));
    assert_eq!(restored["changed"], 3);
    assert_eq!(
        get(&web, &cookie, "/api/tasks?scope=trash").as_array().unwrap().len(),
        0
    );
    call(&web, &cookie, json!({ "op": "batchBack", "steps": restored["backs"] }));
    assert_eq!(
        get(&web, &cookie, "/api/tasks?scope=trash").as_array().unwrap().len(),
        3
    );

    // Only the steps of a batch are taken as its way back.
    let refused = ureq::post(&format!("{}/api/call", web.base))
        .set("Cookie", &cookie)
        .set("X-Lists", "1")
        .send_json(json!({ "op": "batchBack", "steps": [{ "op": "emptyTrash" }] }));
    assert_ne!(status(refused), 200);
    assert_eq!(
        get(&web, &cookie, "/api/tasks?scope=trash").as_array().unwrap().len(),
        3
    );
}

#[test]
fn r125_a_task_of_a_project_comes_with_the_dates_it_goes_by() {
    let web = web(None);
    let project = call(&web, "", json!({ "op": "quickAdd", "text": "п", "scope": "inbox" }));
    let id = project["id"].as_str().unwrap().to_string();
    call(&web, "", json!({ "op": "setProject", "id": id, "value": true }));
    call(&web, "", json!({ "op": "setDue", "id": id, "value": "2030-01-10" }));
    call(&web, "", json!({ "op": "setStart", "id": id, "value": "2030-01-05" }));
    let task = call(&web, "", json!({ "op": "addSubtask", "parent": id, "title": "т" }));
    call(
        &web,
        "",
        json!({ "op": "setStart", "id": task["id"], "value": "2030-01-01" }),
    );

    let upcoming = get(&web, "", "/api/tasks?scope=upcoming");
    assert_eq!(upcoming.as_array().unwrap().len(), 1, "the project is not a row (R120)");
    let row = &upcoming[0];
    assert_eq!(row["title"], "т");
    assert!(row["due"].is_null(), "only the task's own due date is stored");
    assert_eq!(row["effectiveDue"], "2030-01-10");
    assert_eq!(row["start"], "2030-01-01");
    assert_eq!(row["effectiveStart"], "2030-01-05");
}
