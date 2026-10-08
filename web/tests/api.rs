//! The web server over HTTP: login, the session cookie, and a task's life
//! through the JSON interface.

use lists_core::SyncConfig;
use lists_web::{start, Config};
use serde_json::{json, Value};

struct Web {
    base: String,
    _dir: tempfile::TempDir,
}

fn web(password: Option<&str>) -> Web {
    let dir = tempfile::tempdir().unwrap();
    let running = start(Config {
        data_dir: dir.path().to_string_lossy().into_owned(),
        listen: "127.0.0.1:0".into(),
        password: password.map(str::to_string),
        oidc: None,
        sync: SyncConfig::Off,
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

    // Typed into Today without a date: it is due today.
    let quick = call(
        &web,
        &cookie,
        json!({ "op": "quickAdd", "text": "позвонить", "scope": "today", "today": "2026-10-05" }),
    );
    assert_eq!(quick["due"], "2026-10-05");

    call(&web, &cookie, json!({ "op": "delete", "id": id }));
    assert_eq!(
        get(&web, &cookie, "/api/tasks?scope=trash").as_array().unwrap().len(),
        1
    );
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

    call(
        &web,
        "",
        json!({ "op": "updateFilter", "id": fid, "name": "Без даты", "spec": { "due": { "kind": "nodate" } } }),
    );
    assert_eq!(
        get(&web, "", &format!("/api/tasks?scope=filter%3A{fid}"))[0]["title"],
        "Запуск сайта"
    );
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
    assert_eq!(get(&web, &cookie, "/api/overview")["keepDone"], 5);

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
    assert!((1..=301).contains(&left), "within the five minutes: {left}");

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
