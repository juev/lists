//! The web server over HTTP: login, the session cookie, and a task's life
//! through the JSON interface.

use lists_core::{Store, SyncConfig};
use lists_web::{check_health, start, Config};
use serde_json::{json, Value};

struct Web {
    base: String,
    _dir: tempfile::TempDir,
}

fn web(password: Option<&str>) -> Web {
    web_syncing(password, SyncConfig::Off)
}

fn web_syncing(password: Option<&str>, sync: SyncConfig) -> Web {
    web_configured(password, |c| c.sync = sync)
}

fn web_configured(password: Option<&str>, change: impl FnOnce(&mut Config)) -> Web {
    let dir = tempfile::tempdir().unwrap();
    let mut config = Config {
        data_dir: dir.path().to_string_lossy().into_owned(),
        listen: "127.0.0.1:0".into(),
        password: password.map(str::to_string),
        oidc: None,
        sync: SyncConfig::Off,
        sync_password: None,
        sync_passphrase: None,
        push_server: None,
        push_token: None,
        trust_proxy: false,
        secure_cookie: false,
        max_file: None,
        max_task: None,
        vapid_subject: None,
    };
    change(&mut config);
    let running = start(config).unwrap();
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

/// R15, #374: a custom rule as the form of the page sends it, empty parts as null, is kept whole.
#[test]
fn r15_a_custom_rule_from_the_page_is_kept_whole() {
    let web = web(Some("secret"));
    let cookie = login(&web, "secret").unwrap();
    let task = call(
        &web,
        &cookie,
        json!({ "op": "quickAdd", "text": "полить цветы", "scope": "inbox" }),
    );
    let id = task["id"].as_str().unwrap().to_string();
    let rules = [
        json!({ "freq": "weekly", "interval": 2, "weekdays": [1, 3], "monthday": null, "nth": null, "nth_weekday": null,
                "from_done": false, "count": 3, "until": null }),
        json!({ "freq": "monthly", "interval": 2, "weekdays": [], "monthday": null, "nth": -1, "nth_weekday": 5,
                "from_done": true, "count": null, "until": "2027-03-31" }),
    ];
    let kept = [
        json!({ "freq": "weekly", "interval": 2, "weekdays": [1, 3], "from_done": false, "count": 3 }),
        json!({ "freq": "monthly", "interval": 2, "nth": -1, "nth_weekday": 5, "from_done": true, "until": "2027-03-31" }),
    ];
    for (rule, expected) in rules.into_iter().zip(kept) {
        call(&web, &cookie, json!({ "op": "setRepeat", "id": id, "value": rule }));
        let detail = get(&web, &cookie, &format!("/api/task?id={id}"));
        assert_eq!(detail["task"]["repeat"], expected);
    }
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
    let task = other.quick_add("с файлом".into(), None, false, None).unwrap();
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

/// R141: the part of a file a request asks for.
#[allow(clippy::result_large_err)]
fn partial(web: &Web, url: &str, range: &str) -> Result<ureq::Response, ureq::Error> {
    ureq::get(&format!("{}{url}", web.base)).set("Range", range).call()
}

#[test]
fn r141_a_file_is_served_whole_and_in_parts() {
    let web = web(None);
    let task = call(&web, "", json!({ "op": "quickAdd", "text": "с файлом" }));
    let id = task["id"].as_str().unwrap();
    let file = upload(&web, id, "digits.txt", b"0123456789");
    let url = format!("/api/file?task={id}&id={}", file["id"].as_str().unwrap());

    let whole = ureq::get(&format!("{}{url}", web.base)).call().unwrap();
    assert_eq!(whole.status(), 200);
    assert_eq!(whole.header("Accept-Ranges"), Some("bytes"));
    assert_eq!(whole.header("Content-Range"), None);
    assert_eq!(whole.into_string().unwrap(), "0123456789");

    for (range, wanted, content_range) in [
        ("bytes=2-4", "234", "bytes 2-4/10"),
        ("bytes=8-", "89", "bytes 8-9/10"),
        ("bytes=-3", "789", "bytes 7-9/10"),
        ("bytes=0-100", "0123456789", "bytes 0-9/10"),
    ] {
        let part = partial(&web, &url, range).unwrap();
        assert_eq!(part.status(), 206, "{range}");
        assert_eq!(part.header("Content-Range"), Some(content_range), "{range}");
        assert_eq!(part.header("Accept-Ranges"), Some("bytes"), "{range}");
        assert_eq!(part.into_string().unwrap(), wanted, "{range}");
    }

    // Beyond the end, backwards, and of an empty file.
    for range in ["bytes=20-", "bytes=5-3", "bytes=10-"] {
        match partial(&web, &url, range) {
            Err(ureq::Error::Status(416, response)) => {
                assert_eq!(response.header("Content-Range"), Some("bytes */10"), "{range}");
                assert_eq!(response.header("Accept-Ranges"), Some("bytes"), "{range}");
            }
            other => panic!("{range}: {other:?}"),
        }
    }
    // A range that cannot be understood is ignored: the whole file is a valid answer.
    let ignored = partial(&web, &url, "bytes=abc").unwrap();
    assert_eq!(ignored.status(), 200);
    assert_eq!(ignored.into_string().unwrap(), "0123456789");

    // A range of a file shown in place keeps the headers that make it safe.
    let image = upload(&web, id, "photo.png", b"png bytes");
    let shown = format!("/api/file?task={id}&id={}&view=1", image["id"].as_str().unwrap());
    let part = partial(&web, &shown, "bytes=0-2").unwrap();
    assert_eq!(part.status(), 206);
    assert_eq!(part.header("Content-Type"), Some("image/png"));
    assert_eq!(part.header("Content-Range"), Some("bytes 0-2/9"));
    assert!(part.header("Content-Security-Policy").unwrap().contains("sandbox"));

    let empty = upload(&web, id, "empty.txt", b"");
    let empty_url = format!("/api/file?task={id}&id={}", empty["id"].as_str().unwrap());
    assert!(matches!(
        partial(&web, &empty_url, "bytes=0-"),
        Err(ureq::Error::Status(416, _))
    ));

    // HEAD has the headers of the whole file and no body.
    let head = ureq::request("HEAD", &format!("{}{url}", web.base)).call().unwrap();
    assert_eq!(head.status(), 200);
    assert_eq!(head.header("Accept-Ranges"), Some("bytes"));
    assert_eq!(head.into_string().unwrap(), "");
}

#[test]
fn r140_an_upload_above_the_limit_is_refused() {
    let web = web_configured(None, |c| {
        c.max_file = Some(10);
        c.max_task = Some(15);
    });
    let task = call(&web, "", json!({ "op": "quickAdd", "text": "с большим файлом" }));
    let id = task["id"].as_str().unwrap();
    let upload_with = |data: &[u8]| {
        status(
            ureq::post(&format!("{}/api/upload?task={id}&name=file.bin", web.base))
                .set("X-Lists", "1")
                .send_bytes(data),
        )
    };
    assert_eq!(upload_with(b"0123456789A"), 413, "one file above the file limit");
    // Chunked, without a declared length: the limit stops the body while it is read.
    assert_eq!(
        status(
            ureq::post(&format!("{}/api/upload?task={id}&name=file.bin", web.base))
                .set("X-Lists", "1")
                .send(std::io::Cursor::new(b"0123456789A".to_vec()))
        ),
        413
    );

    let listed = get(&web, "", &format!("/api/task?id={id}"));
    assert_eq!(listed["attachments"].as_array().unwrap().len(), 0);

    // The task limit counts what the task already holds.
    assert_eq!(upload_with(b"0123456789"), 200, "exactly the file limit");
    assert_eq!(upload_with(b"0123456789"), 413, "the task has no room for another");
    let listed = get(&web, "", &format!("/api/task?id={id}"));
    assert_eq!(listed["attachments"].as_array().unwrap().len(), 1);
}

#[test]
fn r126_a_project_is_completed_from_the_sidebar_and_comes_back_on_undo() {
    let web = web(None);
    let project = call(&web, "", json!({ "op": "quickAdd", "text": "Переезд" }));
    let id = project["id"].as_str().unwrap().to_string();
    call(&web, "", json!({ "op": "setProject", "id": id, "value": true }));
    let scope = format!("project:{id}");
    let open = call(&web, "", json!({ "op": "quickAdd", "text": "Коробки", "scope": scope }));
    let done = call(
        &web,
        "",
        json!({ "op": "quickAdd", "text": "Грузчики", "scope": scope }),
    );
    call(&web, "", json!({ "op": "complete", "id": done["id"] }));

    call(&web, "", json!({ "op": "complete", "id": id }));
    let overview = get(&web, "", "/api/overview");
    assert_eq!(
        overview["projects"].as_array().unwrap().len(),
        0,
        "it leaves the sidebar (R32)"
    );
    let task = get(&web, "", &format!("/api/task?id={}", open["id"].as_str().unwrap()));
    assert!(
        !task["task"]["done"].is_null(),
        "its open task is completed with it (R11)"
    );

    call(&web, "", json!({ "op": "undoClose", "id": id }));
    let overview = get(&web, "", "/api/overview");
    assert_eq!(overview["projects"][0]["title"], "Переезд");
    assert_eq!(overview["projects"][0]["subtasks"], 2);
    assert_eq!(
        overview["projects"][0]["subtasksDone"], 1,
        "the task completed before stays completed"
    );
}

#[test]
fn r127_a_project_is_created_in_the_list_of_the_view() {
    let web = web(None);
    let work = call(&web, "", json!({ "op": "createList", "name": "Работа" }));
    let work_id = work["id"].as_str().unwrap().to_string();
    let made = call(
        &web,
        "",
        json!({ "op": "createProject", "title": "Отпуск", "scope": format!("list:{work_id}") }),
    );
    assert_eq!(made["project"], true);
    assert_eq!(made["list"], work_id.as_str());
    let id = made["id"].as_str().unwrap().to_string();

    // In the view of a project the new one goes to the list of that project.
    let inner = call(
        &web,
        "",
        json!({ "op": "createProject", "title": "Билеты", "scope": format!("project:{id}") }),
    );
    assert_eq!(inner["list"], work_id.as_str());
    assert!(
        inner["parent"].is_null(),
        "a project is top-level, not a task of the open one"
    );

    // A view without a list of its own: the default list for new tasks (R40).
    let today = call(
        &web,
        "",
        json!({ "op": "createProject", "title": "Ремонт", "scope": "today" }),
    );
    assert_eq!(today["list"], "inbox");

    let overview = get(&web, "", "/api/overview");
    let titles: Vec<&str> = overview["projects"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["title"].as_str().unwrap())
        .collect();
    assert_eq!(titles.len(), 3);
    for title in ["Отпуск", "Билеты", "Ремонт"] {
        assert!(titles.contains(&title), "{title} is in the sidebar");
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

#[test]
fn r128_the_completion_of_a_repeat_is_taken_back() {
    let web = web(Some("secret"));
    let cookie = login(&web, "secret").unwrap();
    let t = call(
        &web,
        &cookie,
        json!({ "op": "quickAdd", "text": "зарядка", "scope": "inbox" }),
    );
    let id = t["id"].as_str().unwrap().to_string();
    call(
        &web,
        &cookie,
        json!({ "op": "setDue", "id": id, "value": "2031-01-02" }),
    );
    call(
        &web,
        &cookie,
        json!({ "op": "setRepeat", "id": id, "value": { "freq": "daily", "interval": 1 } }),
    );
    let due = || get(&web, &cookie, &format!("/api/task?id={id}"))["task"]["due"].clone();
    let records = || {
        get(&web, &cookie, "/api/tasks?scope=completed")
            .as_array()
            .unwrap()
            .clone()
    };

    // A batch is taken back for a repeating task as well.
    call(
        &web,
        &cookie,
        json!({ "op": "batch", "action": "complete", "ids": [id] }),
    );
    assert_eq!(due(), "2031-01-03");
    call(&web, &cookie, json!({ "op": "undo" }));
    assert_eq!(due(), "2031-01-02");
    assert!(records().is_empty());

    // The mark of the record does the same.
    call(&web, &cookie, json!({ "op": "complete", "id": id }));
    let record = records()[0]["id"].clone();
    assert_eq!(records()[0]["undoable"], true, "R133: its mark is on in Completed");
    call(&web, &cookie, json!({ "op": "reopen", "id": record }));
    assert_eq!(due(), "2031-01-02");
    assert!(records().is_empty());

    // R133: once the date has changed, the record keeps no mark.
    call(&web, &cookie, json!({ "op": "complete", "id": id }));
    call(
        &web,
        &cookie,
        json!({ "op": "setDue", "id": id, "value": "2031-02-01" }),
    );
    assert_eq!(records()[0]["undoable"], false);
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
    call(&web, &cookie, json!({ "op": "undo" }));
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
    call(&web, &cookie, json!({ "op": "undo" }));
    assert_eq!(task(&b)["tags"], json!([]));
    let due = task(&c)["due"].clone();
    let dated = call(
        &web,
        &cookie,
        json!({ "op": "batch", "action": "due", "value": "2031-01-02", "ids": ids }),
    );
    assert_eq!(dated["changed"], 3);
    call(&web, &cookie, json!({ "op": "undo" }));
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
    call(&web, &cookie, json!({ "op": "undo" }));
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
    call(&web, &cookie, json!({ "op": "undo" }));
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
    call(&web, &cookie, json!({ "op": "undo" }));
    assert_eq!(
        get(&web, &cookie, "/api/tasks?scope=trash").as_array().unwrap().len(),
        3
    );
}

#[test]
fn r131_each_session_takes_back_its_own_actions() {
    let web = web(Some("secret"));
    let (a, b) = (login(&web, "secret").unwrap(), login(&web, "secret").unwrap());
    let id = call(&web, &a, json!({ "op": "quickAdd", "text": "а", "scope": "inbox" }))["id"].clone();
    let due = || get(&web, &a, &format!("/api/task?id={}", id.as_str().unwrap()))["task"]["due"].clone();
    call(&web, &a, json!({ "op": "setDue", "id": id, "value": "2031-01-02" }));

    assert_eq!(call(&web, &b, json!({ "op": "undo" }))["changed"], 0);
    assert_eq!(due(), "2031-01-02", "another session leaves it alone");
    assert_eq!(call(&web, &a, json!({ "op": "undo" }))["changed"], 1);
    assert_eq!(due(), Value::Null);
    call(&web, &a, json!({ "op": "undo" }));
    let trash = get(&web, &a, "/api/tasks?scope=trash");
    assert_eq!(trash[0]["title"], "а", "the creation goes last, to the trash");
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

#[test]
fn r129_tasks_go_into_a_project_one_by_one_and_in_a_batch_and_are_taken_back() {
    let web = web(None);
    let add = |text: &str| {
        call(&web, "", json!({ "op": "quickAdd", "text": text, "scope": "inbox" }))["id"]
            .as_str()
            .unwrap()
            .to_string()
    };
    let task = |id: &str| get(&web, "", &format!("/api/task?id={id}"))["task"].clone();
    let home = call(&web, "", json!({ "op": "createList", "name": "Дом" }))["id"].clone();
    let project = call(
        &web,
        "",
        json!({ "op": "createProject", "title": "Ремонт", "scope": format!("list:{}", home.as_str().unwrap()) }),
    )["id"]
        .as_str()
        .unwrap()
        .to_string();
    let (a, b, c) = (add("а"), add("б"), add("в"));
    call(&web, "", json!({ "op": "addSubtask", "parent": c, "title": "строка" }));

    // One task in, and out again by choosing a list.
    call(&web, "", json!({ "op": "moveToProject", "id": a, "project": project }));
    assert_eq!(
        (task(&a)["parent"].as_str(), &task(&a)["list"]),
        (Some(project.as_str()), &home)
    );
    call(&web, "", json!({ "op": "moveToList", "id": a, "list": home }));
    assert!(task(&a)["parent"].is_null());
    assert_eq!(task(&a)["list"], home);

    // A batch passes over the task with a subtask, the project and its subtask line.
    let line = get(&web, "", &format!("/api/task?id={c}"))["subtasks"][0]["id"]
        .as_str()
        .map(str::to_string);
    assert!(line.is_some());
    let mut ids = vec![a.clone(), b.clone(), c.clone(), project.clone()];
    ids.extend(line);
    let moved = call(
        &web,
        "",
        json!({ "op": "batch", "action": "project", "value": project, "ids": ids }),
    );
    assert_eq!(moved["changed"], 2);
    assert_eq!(task(&b)["parent"].as_str(), Some(project.as_str()));
    assert!(task(&c)["parent"].is_null());
    call(&web, "", json!({ "op": "undo" }));
    assert!(task(&b)["parent"].is_null());
    assert_eq!(task(&b)["list"], "inbox");
    assert_eq!(task(&a)["list"], home, "back to its former list");

    // A list in the same batch takes a task out of the project; a subtask line is passed over.
    call(&web, "", json!({ "op": "moveToProject", "id": b, "project": project }));
    let out = call(
        &web,
        "",
        json!({ "op": "batch", "action": "move", "value": home, "ids": ids }),
    );
    assert_eq!(
        out["changed"], 2,
        "а and the project are in the list already, the line stays"
    );
    assert_eq!(task(&c)["list"], home);
    assert!(task(&b)["parent"].is_null());
}

#[test]
fn r130_quick_add_puts_the_task_first() {
    let web = web(None);
    for text in ["а", "б", "в"] {
        call(&web, "", json!({ "op": "quickAdd", "text": text, "scope": "inbox" }));
    }
    let inbox = get(&web, "", "/api/tasks?scope=inbox");
    let titles: Vec<&str> = inbox
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["title"].as_str().unwrap())
        .collect();
    assert_eq!(titles, ["в", "б", "а"]);

    let project = call(
        &web,
        "",
        json!({ "op": "createProject", "title": "Проект", "scope": "inbox" }),
    );
    let id = project["id"].as_str().unwrap().to_string();
    for text in ["п1", "п2"] {
        call(
            &web,
            "",
            json!({ "op": "quickAdd", "text": text, "scope": format!("project:{id}") }),
        );
    }
    let tasks = get(&web, "", &format!("/api/tasks?scope=project%3A{id}"));
    let titles: Vec<&str> = tasks
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["title"].as_str().unwrap())
        .collect();
    assert_eq!(titles, ["п2", "п1"]);
}

#[test]
fn r134_wrong_passwords_do_not_hold_the_server() {
    let web = web(Some("secret"));
    let started = std::time::Instant::now();
    let tries: Vec<_> = (0..4)
        .map(|_| {
            let base = web.base.clone();
            std::thread::spawn(move || {
                status(ureq::post(&format!("{base}/api/login")).send_json(json!({ "password": "wrong" })))
            })
        })
        .collect();
    std::thread::sleep(std::time::Duration::from_millis(50));
    assert_eq!(status(ureq::get(&format!("{}/", web.base)).call()), 200);
    let page = started.elapsed();
    let codes: Vec<u16> = tries.into_iter().map(|t| t.join().unwrap()).collect();
    assert_eq!(codes, [401; 4]);
    assert!(page < std::time::Duration::from_millis(400), "the page took {page:?}");
    assert!(
        started.elapsed() < std::time::Duration::from_millis(400),
        "a wrong password is answered at once"
    );
}

/// Sends the head of a login that promises a body and never sends it. tiny_http reads
/// a body up to 1 KB itself before handing the request over, so this one is larger.
/// It comes from another client, since an attempt counts as failed until it succeeds.
fn unfinished_login(web: &Web) -> std::net::TcpStream {
    use std::io::Write;
    let mut stream = std::net::TcpStream::connect(web.base.trim_start_matches("http://")).unwrap();
    stream
        .write_all(b"POST /api/login HTTP/1.1\r\nHost: lists\r\nContent-Type: application/json\r\nX-Forwarded-For: 203.0.113.9\r\nContent-Length: 2000\r\n\r\n{")
        .unwrap();
    stream
}

fn login_from(web: &Web, password: &str, forwarded: Option<&str>) -> ureq::Response {
    let mut request = ureq::post(&format!("{}/api/login", web.base));
    if let Some(address) = forwarded {
        request = request.set("X-Forwarded-For", address);
    }
    match request.send_json(json!({ "password": password })) {
        Ok(r) => r,
        Err(ureq::Error::Status(_, r)) => r,
        Err(e) => panic!("{e}"),
    }
}

#[test]
fn r134_unfinished_bodies_do_not_hold_the_server() {
    let web = web_configured(Some("secret"), |c| c.trust_proxy = true);
    let streams: Vec<_> = (0..8).map(|_| unfinished_login(&web)).collect();
    std::thread::sleep(std::time::Duration::from_millis(100));
    let started = std::time::Instant::now();
    let agent = ureq::AgentBuilder::new()
        .timeout(std::time::Duration::from_secs(2))
        .build();
    assert_eq!(status(agent.get(&format!("{}/", web.base)).call()), 200);
    assert!(login(&web, "secret").is_some());
    assert!(
        started.elapsed() < std::time::Duration::from_millis(500),
        "took {:?}",
        started.elapsed()
    );
    drop(streams);
}

#[test]
fn r134_a_login_body_is_small() {
    let web = web(Some("secret"));
    let big = "x".repeat(5000);
    assert_eq!(
        status(ureq::post(&format!("{}/api/login", web.base)).send_json(json!({ "password": big }))),
        413
    );
    assert!(login(&web, "secret").is_some(), "a refused body counts as no failure");
}

#[test]
fn r134_failed_logins_are_limited_per_client() {
    let web = web(Some("secret"));
    for _ in 0..5 {
        assert_eq!(login_from(&web, "wrong", None).status(), 401);
    }
    let refused = login_from(&web, "secret", None);
    assert_eq!(refused.status(), 429, "the right password is not checked either");
    let wait: u64 = refused.header("Retry-After").unwrap().parse().unwrap();
    assert!((1..=60).contains(&wait), "Retry-After: {wait}");
    assert_eq!(
        login_from(&web, "secret", Some("203.0.113.7")).status(),
        429,
        "without LISTS_TRUST_PROXY the header is not believed"
    );
}

#[test]
fn r134_behind_a_proxy_the_client_is_the_forwarded_address() {
    let web = web_configured(Some("secret"), |c| c.trust_proxy = true);
    for _ in 0..5 {
        assert_eq!(
            login_from(&web, "wrong", Some("198.51.100.1, 203.0.113.7")).status(),
            401
        );
    }
    assert_eq!(login_from(&web, "secret", Some("203.0.113.7")).status(), 429);
    assert_eq!(
        login_from(&web, "secret", Some("203.0.113.7, 203.0.113.8")).status(),
        200,
        "the address the proxy appended is the last one"
    );
    assert_eq!(
        login_from(&web, "secret", None).status(),
        200,
        "no header: the connection's address"
    );
}

#[test]
fn r134_a_good_login_clears_the_count() {
    let web = web(Some("secret"));
    for _ in 0..4 {
        assert_eq!(login_from(&web, "wrong", None).status(), 401);
    }
    assert_eq!(login_from(&web, "secret", None).status(), 200);
    for _ in 0..4 {
        assert_eq!(login_from(&web, "wrong", None).status(), 401);
    }
    assert_eq!(login_from(&web, "secret", None).status(), 200);
}

#[test]
fn r134_the_cookie_is_secure_over_https() {
    let plain = web(Some("secret"));
    let cookie = login_from(&plain, "secret", None)
        .header("Set-Cookie")
        .unwrap()
        .to_string();
    assert!(!cookie.contains("Secure"), "{cookie}");
    let secure = web_configured(Some("secret"), |c| c.secure_cookie = true);
    let cookie = login_from(&secure, "secret", None)
        .header("Set-Cookie")
        .unwrap()
        .to_string();
    assert!(cookie.ends_with("; Secure") && cookie.contains("HttpOnly"), "{cookie}");
}

#[test]
fn r134_concurrent_guesses_do_not_pass_the_limit() {
    let web = web(Some("secret"));
    let tries: Vec<_> = (0..20)
        .map(|_| {
            let base = web.base.clone();
            std::thread::spawn(move || {
                status(ureq::post(&format!("{base}/api/login")).send_json(json!({ "password": "wrong" })))
            })
        })
        .collect();
    let codes: Vec<u16> = tries.into_iter().map(|t| t.join().unwrap()).collect();
    assert_eq!(codes.iter().filter(|c| **c == 401).count(), 5, "{codes:?}");
    assert_eq!(codes.iter().filter(|c| **c == 429).count(), 15, "{codes:?}");
}

#[test]
fn r135_each_browser_gets_today_of_its_own_zone() {
    let web = web(None);
    // Fourteen hours east and twelve west are a day or two apart at any moment.
    let (east, west) = ("840", "-720");
    let quick_add = |zone: &str, text: &str| -> Value {
        ureq::post(&format!("{}/api/call", web.base))
            .set("X-Lists", "1")
            .set("X-Lists-Zone", zone)
            .send_json(json!({ "op": "quickAdd", "text": text, "scope": "inbox" }))
            .unwrap()
            .into_json()
            .unwrap()
    };
    let today = |zone: &str| -> Vec<String> {
        let tasks: Value = ureq::get(&format!("{}/api/tasks?scope=today", web.base))
            .set("X-Lists-Zone", zone)
            .call()
            .unwrap()
            .into_json()
            .unwrap();
        let mut titles: Vec<String> = tasks
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["title"].as_str().unwrap().to_string())
            .collect();
        titles.sort();
        titles
    };

    let early = quick_add(east, "восток 9:00")["due"].as_str().unwrap().to_string();
    let late = quick_add(west, "запад 9:00")["due"].as_str().unwrap().to_string();
    assert!(early.ends_with("T09:00") && late.ends_with("T09:00"), "{early} {late}");
    assert!(early > late, "the browser's date, not the server's: {early} {late}");

    assert_eq!(today(east), ["восток", "запад"]);
    assert_eq!(today(west), ["запад"]);
    for zone in ["", "abc", "900"] {
        let tasks = ureq::get(&format!("{}/api/tasks?scope=today", web.base))
            .set("X-Lists-Zone", zone)
            .call()
            .unwrap();
        assert_eq!(tasks.status(), 200, "a zone that is not one is the server's: {zone:?}");
    }
}

#[test]
fn r144_healthz_answers_without_a_session() {
    let web = web(Some("secret"));
    let health = ureq::get(&format!("{}/healthz", web.base)).call().unwrap();
    assert_eq!(health.status(), 200);
    assert_eq!(health.into_string().unwrap(), "ok");
    assert_eq!(status(ureq::get(&format!("{}/api/overview", web.base)).call()), 401);
}

#[test]
fn r144_the_health_check_asks_a_wildcard_address_on_loopback() {
    let web = web_configured(Some("secret"), |c| c.listen = "0.0.0.0:0".into());
    let port = web.base.rsplit(':').next().unwrap();
    assert_eq!(check_health(&format!("0.0.0.0:{port}")), Ok(()));
    assert_eq!(check_health(&format!("127.0.0.1:{port}")), Ok(()));
}

#[test]
fn r144_lists_web_healthcheck_exits_with_0_only_when_the_server_answers() {
    let web = web(Some("secret"));
    let healthcheck = |listen: &str| {
        std::process::Command::new(env!("CARGO_BIN_EXE_lists-web"))
            .arg("healthcheck")
            .env("LISTS_WEB_LISTEN", listen)
            .output()
            .unwrap()
    };
    let up = healthcheck(web.base.trim_start_matches("http://"));
    assert_eq!(up.status.code(), Some(0), "{}", String::from_utf8_lossy(&up.stderr));

    let free = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap();
    let down = healthcheck(&free.to_string());
    assert_eq!(down.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&down.stderr).contains("healthcheck"));
}

#[test]
fn s58_the_server_opens_an_encrypted_storage_with_the_passphrase_it_is_given() {
    let storage = tempfile::tempdir().unwrap();
    let folder = SyncConfig::Folder {
        path: storage.path().to_string_lossy().into_owned(),
    };
    let data = tempfile::tempdir().unwrap();
    let other = Store::open(data.path().to_string_lossy().into_owned()).unwrap();
    other.set_sync_config(folder.clone()).unwrap();
    let task = other.quick_add("под замком".into(), None, false, None).unwrap();
    other.encrypt_storage("фраза-пароль".into()).unwrap();

    // Without the passphrase the server says why it does not sync.
    let locked = web_syncing(None, folder.clone());
    let refused = ureq::post(&format!("{}/api/call", locked.base))
        .set("X-Lists", "1")
        .send_json(json!({ "op": "sync" }));
    assert_eq!(status(refused), 502);
    let error = get(&locked, "", "/api/overview")["sync"]["lastError"].to_string();
    assert!(error.contains("passphrase"), "{error}");

    let web = web_configured(None, |c| {
        c.sync = folder;
        c.sync_passphrase = Some("фраза-пароль".into());
    });
    call(&web, "", json!({ "op": "sync" }));
    let path = format!("/api/task?id={}", task.id);
    assert_eq!(get(&web, "", &path)["task"]["title"], "под замком");
}

#[test]
fn r147_r148_notifications_over_the_api() {
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use base64::Engine;
    use p256::elliptic_curve::sec1::ToEncodedPoint;

    let web = web(Some("secret"));
    let sw = ureq::get(&format!("{}/sw.js", web.base)).call().unwrap();
    assert!(
        sw.content_type().contains("javascript"),
        "the worker is served without a session"
    );
    assert_eq!(
        status(ureq::get(&format!("{}/api/notifications/key", web.base)).call()),
        401
    );
    let cookie = login(&web, "secret").unwrap();
    let key = get(&web, &cookie, "/api/notifications/key")["key"]
        .as_str()
        .unwrap()
        .to_string();
    let key = URL_SAFE_NO_PAD.decode(key).unwrap();
    assert!(p256::PublicKey::from_sec1_bytes(&key).is_ok() && key.len() == 65);

    let browser = p256::SecretKey::random(&mut rand_core::OsRng);
    let subscription = |endpoint: &str| {
        json!({
            "endpoint": endpoint,
            "keys": {
                "p256dh": URL_SAFE_NO_PAD.encode(browser.public_key().to_encoded_point(false).as_bytes()),
                "auth": URL_SAFE_NO_PAD.encode([1u8; 16]),
            },
            "zone": "Europe/Moscow", "offset": 180,
        })
    };
    // The status and the answer.
    let post = |path: &str, body: Value| -> (u16, Value) {
        match ureq::post(&format!("{}{path}", web.base))
            .set("Cookie", &cookie)
            .set("X-Lists", "1")
            .send_json(body)
        {
            Ok(r) => (r.status(), r.into_json().unwrap()),
            Err(ureq::Error::Status(code, r)) => (code, r.into_json().unwrap()),
            Err(e) => panic!("{e}"),
        }
    };
    let (code, answer) = post(
        "/api/notifications/subscribe",
        subscription("https://push.example.net/a"),
    );
    assert_eq!(code, 200);
    assert_eq!(
        answer["settings"],
        json!({ "leads": [0], "allDay": "09:00", "summary": null })
    );
    assert_eq!(
        post(
            "/api/notifications/subscribe",
            subscription("http://push.example.net/a")
        )
        .0,
        400
    );
    assert_eq!(
        status(
            ureq::post(&format!("{}/api/notifications/subscribe", web.base))
                .set("Cookie", &cookie)
                .send_json(subscription("https://push.example.net/a"))
        ),
        400,
        "without X-Lists"
    );
    assert_eq!(
        post(
            "/api/notifications/test",
            json!({ "endpoint": "https://push.example.net/other" })
        )
        .0,
        404
    );
    let (_, gone) = post(
        "/api/notifications/unsubscribe",
        json!({ "endpoint": "https://push.example.net/a" }),
    );
    assert_eq!(gone["known"], true);
    assert_eq!(
        post(
            "/api/notifications/test",
            json!({ "endpoint": "https://push.example.net/a" })
        )
        .0,
        404,
        "an unsubscribed browser gets nothing"
    );
}

/// R150–R152: the status and the answer of a request made with `token`.
fn with_token(web: &Web, token: &str, method: &str, path: &str, body: Option<Value>) -> (u16, Value, Option<String>) {
    let request =
        ureq::request(method, &format!("{}{path}", web.base)).set("Authorization", &format!("Bearer {token}"));
    let result = match body {
        Some(body) => request.send_json(body),
        None => request.call(),
    };
    let response = match result {
        Ok(r) => r,
        Err(ureq::Error::Status(_, r)) => r,
        Err(e) => panic!("{e}"),
    };
    let retry = response.header("Retry-After").map(str::to_string);
    (response.status(), response.into_json().unwrap_or(Value::Null), retry)
}

fn make_token(web: &Web, cookie: &str, name: &str, scope: &str) -> String {
    ureq::post(&format!("{}/api/tokens", web.base))
        .set("Cookie", cookie)
        .set("X-Lists", "1")
        .send_json(json!({ "name": name, "scope": scope }))
        .unwrap()
        .into_json::<Value>()
        .unwrap()["token"]
        .as_str()
        .unwrap()
        .to_string()
}

#[test]
fn r150_r151_tokens_read_write_and_are_revoked() {
    let web = web(Some("secret"));
    let cookie = login(&web, "secret").unwrap();
    let reader = make_token(&web, &cookie, "скрипт", "read");
    let writer = make_token(&web, &cookie, "ярлык", "write");
    let listed = get(&web, &cookie, "/api/tokens");
    assert_eq!(
        listed
            .as_array()
            .unwrap()
            .iter()
            .map(|t| (t["name"].as_str().unwrap(), t["scope"].as_str().unwrap()))
            .collect::<Vec<_>>(),
        [("скрипт", "read"), ("ярлык", "write")]
    );
    assert!(listed[0].get("token").is_none() && listed[0].get("hash").is_none());

    assert_eq!(with_token(&web, &reader, "GET", "/api/overview", None).0, 200);
    assert_eq!(with_token(&web, &reader, "GET", "/api/tasks?scope=today", None).0, 200);
    let refused = with_token(
        &web,
        &reader,
        "POST",
        "/api/call",
        Some(json!({ "op": "quickAdd", "text": "нет" })),
    );
    assert_eq!(refused.0, 403);

    // No cookie and no X-Lists: a token is not sent by a browser on its own.
    let (code, made, _) = with_token(
        &web,
        &writer,
        "POST",
        "/api/call",
        Some(json!({ "op": "quickAdd", "text": "из ярлыка", "scope": "inbox" })),
    );
    assert_eq!(code, 200, "{made}");
    // The browser makes a change of its own; the token's undo takes back the token's change.
    call(
        &web,
        &cookie,
        json!({ "op": "quickAdd", "text": "из браузера", "scope": "inbox" }),
    );
    assert_eq!(
        with_token(&web, &writer, "POST", "/api/call", Some(json!({ "op": "undo" }))).0,
        200
    );
    let titles: Vec<String> = get(&web, &cookie, "/api/tasks?scope=inbox")
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["title"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(titles, ["из браузера"]);

    for (method, path, body) in [
        ("GET", "/api/tokens", None),
        ("POST", "/api/tokens", Some(json!({ "name": "ещё", "scope": "write" }))),
        ("POST", "/api/logout", Some(json!({}))),
        ("POST", "/api/notifications/subscribe", Some(json!({}))),
    ] {
        assert_eq!(with_token(&web, &writer, method, path, body).0, 403, "{method} {path}");
    }
    assert!(get(&web, &cookie, "/api/tokens")[1]["used"].is_string());

    let id = get(&web, &cookie, "/api/tokens")[1]["id"].as_str().unwrap().to_string();
    let revoked: Value = ureq::post(&format!("{}/api/tokens/revoke", web.base))
        .set("Cookie", &cookie)
        .set("X-Lists", "1")
        .send_json(json!({ "id": id }))
        .unwrap()
        .into_json()
        .unwrap();
    assert_eq!(revoked["known"], true);
    assert_eq!(with_token(&web, &writer, "GET", "/api/overview", None).0, 401);
    assert_eq!(with_token(&web, &reader, "GET", "/api/overview", None).0, 200);
}

#[test]
fn r152_tokens_are_limited_and_wrong_ones_count_as_failed_logins() {
    let web = web(Some("secret"));
    let cookie = login(&web, "secret").unwrap();
    let token = make_token(&web, &cookie, "много", "read");
    for i in 0..600 {
        assert_eq!(
            with_token(&web, &token, "GET", "/api/counts-not-there", None).0,
            404,
            "request {i}"
        );
    }
    let (code, _, retry) = with_token(&web, &token, "GET", "/api/overview", None);
    assert_eq!(code, 429);
    assert!(retry.is_some_and(|s| s.parse::<u64>().is_ok_and(|s| (1..=61).contains(&s))));

    for _ in 0..5 {
        assert_eq!(with_token(&web, "lists_wrong", "GET", "/api/overview", None).0, 401);
    }
    assert_eq!(with_token(&web, "lists_wrong", "GET", "/api/overview", None).0, 429);
    assert_eq!(
        login(&web, "secret"),
        None,
        "the password login of that client waits as well"
    );
}

#[test]
fn r155_r156_the_export_downloads_as_a_file() {
    let web = web(Some("secret"));
    let cookie = login(&web, "secret").unwrap();
    call(
        &web,
        &cookie,
        json!({ "op": "quickAdd", "text": "в выгрузке", "scope": "inbox" }),
    );
    let response = ureq::get(&format!("{}/api/export", web.base))
        .set("Cookie", &cookie)
        .call()
        .unwrap();
    assert!(response
        .header("Content-Disposition")
        .unwrap()
        .starts_with("attachment; filename=\"Lists-"));
    assert_eq!(response.content_type(), "application/json");
    let v: Value = response.into_json().unwrap();
    assert_eq!(v["format"], "lists");
    assert_eq!(v["tasks"][0]["title"], "в выгрузке");

    let md = ureq::get(&format!("{}/api/export?format=markdown&list=inbox", web.base))
        .set("Cookie", &cookie)
        .call()
        .unwrap();
    assert!(md.header("Content-Disposition").unwrap().ends_with(".md\""));
    assert!(md.into_string().unwrap().contains("## Inbox\n\n- [ ] в выгрузке\n"));
    assert_eq!(
        status(
            ureq::get(&format!("{}/api/export?list=nope", web.base))
                .set("Cookie", &cookie)
                .call()
        ),
        404
    );
    assert_eq!(status(ureq::get(&format!("{}/api/export", web.base)).call()), 401);
}

#[test]
fn r160_the_page_names_the_version_and_the_author() {
    let web = web(Some("secret"));
    let page = ureq::get(&format!("{}/", web.base))
        .call()
        .unwrap()
        .into_string()
        .unwrap();
    assert!(page.contains(&format!("const VERSION = \"{}\";", env!("CARGO_PKG_VERSION"))));
    assert!(!page.contains("{{version}}"));
    assert!(page.contains("https://denis.evsyukov.org"));
    assert!(page.contains("Denis Evsyukov"));
}
