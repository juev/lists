//! Import from other task managers: docs/specs/import.md.

mod common;

use std::io::Write;

use common::*;
use lists_core::*;

/// A backup shaped like the ones 2Do 4.19 for macOS writes: a zip with
/// `2do.db` and the attachment files. Only the columns the importer reads.
fn twodo_backup(dir: &std::path::Path) -> String {
    let db = dir.join("2do.db");
    let _ = std::fs::remove_file(&db);
    let conn = rusqlite::Connection::open(&db).unwrap();
    conn.execute_batch(
        "CREATE TABLE calendars (uid TEXT, title TEXT, colorhex TEXT, isinboxcal INTEGER, isdeleted INTEGER, listtype INTEGER, smartsearch TEXT, displayorder INTEGER);
         CREATE TABLE tasks (primid INTEGER PRIMARY KEY, uid TEXT, calendaruid TEXT, title TEXT, notes TEXT, duedate DOUBLE, duetime DOUBLE, startdate DOUBLE,
            priority INTEGER, iscompleted INTEGER, completeddate DOUBLE, tags TEXT, parent TEXT, tasktype INTEGER, repeattype INTEGER, url TEXT, isdeleted INTEGER, displayorder INTEGER,
            repeatvalue INTEGER DEFAULT 0, recurrence INTEGER DEFAULT 1, recurrenceendtype INTEGER DEFAULT 0, recurrenceendrepeats INTEGER DEFAULT 0, recurrenceenddate DOUBLE DEFAULT 0);
         CREATE TABLE taskattachments (taskuid TEXT, displayname TEXT, fileextension TEXT, relativepath TEXT, isdeleted INTEGER, orderindex INTEGER);
         INSERT INTO calendars VALUES ('all', 'All', '#000000', 0, 0, 1, '', 0), ('inbox', 'Inbox', '#5E7C92', 1, 0, 6, '', 1),
            ('home', 'Дом', '#379417', 0, 0, 0, '', 2), ('smart', 'Smart', '#111111', 0, 0, 0, 'type:overdue', 3), ('gone', 'Удалён', '', 0, 1, 0, '', 4);
         INSERT INTO tasks (uid, calendaruid, title, notes, duedate, duetime, startdate, priority, iscompleted, completeddate, tags, parent, tasktype, repeattype, url, isdeleted, displayorder) VALUES
            ('t1', 'home', 'Полить цветы', 'раз в три дня', 1790510400, 999999, 6406192800, 10, 0, 0, 'дом_~|$$@$$|~_0_~|$$@$$|~__~|$$@$$|~_1_~|$$@$$|~_abc_~|$$@$$|~__~|$$@$$|~__~|$$@$$|~_0', '', 0, 258, '', 0, 1),
            ('t2', 'inbox', 'Ремонт', '', 1790510400, 930, 1790467200, 1, 0, 0, '', '', 2, 0, 'https://example.org', 0, 2),
            ('t3', 'inbox', 'Купить краску', '', 6406192800, 999999, 6406192800, 9, 1, 1790596633, '', 't2', 0, 0, '', 0, 3),
            ('t4', 'home', 'Удалена', '', 6406192800, 999999, 6406192800, 10, 0, 0, '', '', 0, 0, '', 1, 4),
            ('t5', 'home', 'Особый повтор', '', 1790510400, 999999, 6406192800, 10, 0, 0, '', '', 0, 513, '', 0, 5),
            ('t6', 'home', 'Последняя пятница', '', 1790510400, 999999, 6406192800, 5, 0, 0, '', '', 1, 264, '', 0, 6),
            ('t7', 'home', 'Пн, ср, пт', '', 1790510400, 999999, 6406192800, 10, 0, 0, '', '', 0, 84, '', 0, 7);
         UPDATE tasks SET repeatvalue = 6 WHERE uid = 't6';
         UPDATE tasks SET repeatvalue = 1, recurrenceendtype = 2, recurrenceendrepeats = 4 WHERE uid = 't7';
         UPDATE tasks SET repeatvalue = 3 WHERE uid = 't1';
         UPDATE tasks SET repeattype = 258, repeatvalue = 1, recurrence = 2, recurrenceendtype = 1, recurrenceenddate = 1792497600 WHERE uid = 't2';
         INSERT INTO taskattachments VALUES ('t2', 'План.jpg', 'jpg', 'aa/bb/payload.jpg', 0, 0), ('t2', 'evil', 'txt', '../../2do.db', 0, 1),
            ('t1', 'Image', 'jpg', 'cc/dd/payload.jpg', 0, 0);",
    )
    .unwrap();
    drop(conn);
    let path = dir.join("backup.2dodb");
    let mut zip = zip::ZipWriter::new(std::fs::File::create(&path).unwrap());
    let options = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    zip.start_file("2do.db", options).unwrap();
    zip.write_all(&std::fs::read(&db).unwrap()).unwrap();
    zip.start_file("2DoBackupPayload/Attachments/aa/bb/payload.jpg", options)
        .unwrap();
    zip.write_all(b"jpeg bytes").unwrap();
    zip.start_file("2DoBackupPayload/Attachments/cc/dd/payload.jpg", options)
        .unwrap();
    zip.write_all(b"photo bytes").unwrap();
    zip.finish().unwrap();
    path.to_string_lossy().into_owned()
}

#[test]
fn twodo_backup_brings_lists_tasks_subtasks_tags_and_attachments() {
    let d = device();
    let dir = tempfile::tempdir().unwrap();
    let report = d.import_file(twodo_backup(dir.path())).unwrap();
    assert_eq!(
        (report.source.as_str(), report.lists, report.tasks, report.attachments),
        ("2Do", 1, 6, 2)
    );
    assert!(
        report
            .notes
            .iter()
            .any(|n| n.starts_with("4 repeat rules were converted")),
        "{:?}",
        report.notes
    );
    assert!(
        report
            .notes
            .iter()
            .any(|n| n.starts_with("1 repeating tasks use a rule")),
        "{:?}",
        report.notes
    );

    let lists = d.lists().unwrap();
    assert_eq!(
        lists.iter().map(|l| l.name.as_str()).collect::<Vec<_>>(),
        ["", "Дом"],
        "focus, smart and deleted lists are not lists"
    );
    assert_eq!(lists[1].color, "#379417");

    let home = d
        .tasks(Scope::List {
            id: lists[1].id.clone(),
        })
        .unwrap();
    assert_eq!(
        titles(&home),
        ["Полить цветы", "Особый повтор", "Последняя пятница", "Пн, ср, пт"]
    );
    let last_friday = home[2].repeat.clone().unwrap();
    assert_eq!(
        (last_friday.freq, last_friday.nth, last_friday.nth_weekday),
        (Freq::Monthly, Some(-1), Some(5))
    );
    assert_eq!(home[2].priority, Priority::Medium);
    assert!(!home[2].is_project, "a checklist is a plain task");
    let three_days = home[3].repeat.clone().unwrap();
    assert_eq!(
        (three_days.freq, three_days.weekdays.clone(), three_days.count),
        (Freq::Weekly, vec![1, 3, 5], Some(4))
    );
    assert_eq!(
        (home[0].due.as_deref(), home[0].notes.as_str()),
        (Some("2026-09-27"), "раз в три дня")
    );
    assert_eq!(home[0].tags, ["дом"]);
    let every_three_months = home[0].repeat.clone().expect("258 with value 3 is every three months");
    assert_eq!(
        (
            every_three_months.freq,
            every_three_months.interval,
            every_three_months.from_done
        ),
        (Freq::Monthly, 3, false)
    );
    assert_eq!(
        every_three_months.monthday,
        Some(27),
        "the day of the month comes from the due date"
    );
    assert_eq!(
        home[1].tags,
        ["2do-repeat"],
        "a rule that is not understood is flagged, not guessed"
    );
    assert!(home[1].repeat.is_none());

    let inbox = d.tasks(Scope::Inbox).unwrap();
    assert_eq!(titles(&inbox), ["Ремонт"]);
    let project = &inbox[0];
    assert!(project.is_project);
    assert_eq!(project.priority, Priority::High);
    assert_eq!(
        (project.due.as_deref(), project.start.as_deref()),
        (Some("2026-09-27T09:30"), Some("2026-09-27"))
    );
    assert!(project.notes.contains("https://example.org"));
    let monthly = project.repeat.clone().unwrap();
    assert_eq!(
        (
            monthly.freq,
            monthly.interval,
            monthly.from_done,
            monthly.until.as_deref()
        ),
        (Freq::Monthly, 1, true, Some("2026-10-20"))
    );
    let subs = d.subtasks(project.id.clone()).unwrap();
    assert_eq!(titles(&subs), ["Купить краску"]);
    assert!(subs[0].done.is_some() && subs[0].priority == Priority::Low);
    let files = d.attachments(project.id.clone()).unwrap();
    assert_eq!(files.len(), 1, "a path that leaves the backup is ignored");
    assert_eq!(files[0].name, "План.jpg");
    assert_eq!(
        std::fs::read(files[0].local_path.as_ref().unwrap()).unwrap(),
        b"jpeg bytes"
    );

    // Importing the same backup again changes nothing: no duplicates.
    d.import_file(twodo_backup(dir.path())).unwrap();
    assert_eq!(d.tasks(Scope::Inbox).unwrap().len(), 1);
    assert_eq!(d.lists().unwrap().len(), 2);
    assert_eq!(d.attachments(project.id.clone()).unwrap().len(), 1);
}

#[test]
fn todoist_csv_template() {
    let d = device();
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("Work.csv");
    std::fs::write(
        &file,
        "\u{feff}TYPE,CONTENT,DESCRIPTION,PRIORITY,INDENT,AUTHOR,RESPONSIBLE,DATE,DATE_LANG,TIMEZONE\n\
         section,Planning,,,,,,,,\n\
         task,Write the report @quarterly,\"Numbers, then text\",1,1,me (1),,2026-10-09,en,UTC\n\
         note,First comment,,,,,,,,\n\
         task,Collect numbers,,4,2,me (1),,tomorrow,en,UTC\n\
         task,Weekly review,,2,1,me (1),,every monday,en,UTC\n",
    )
    .unwrap();
    let report = d.import_file(file.to_string_lossy().into_owned()).unwrap();
    assert_eq!((report.source.as_str(), report.lists, report.tasks), ("Todoist", 1, 3));

    let list = d.lists().unwrap().into_iter().find(|l| l.name == "Work").unwrap();
    let tasks = d.tasks(Scope::List { id: list.id }).unwrap();
    assert_eq!(titles(&tasks), ["Write the report", "Weekly review"]);
    let first = &tasks[0];
    assert_eq!(first.priority, Priority::High, "1 is the highest in the CSV");
    assert_eq!(first.due.as_deref(), Some("2026-10-09"));
    assert_eq!(first.tags, ["quarterly"]);
    assert_eq!(first.notes, "Numbers, then text\nFirst comment");
    assert_eq!(titles(&d.subtasks(first.id.clone()).unwrap()), ["Collect numbers"]);
    assert!(
        tasks[1].notes.contains("Todoist date: every monday"),
        "a repeat in words is kept as text"
    );
    assert_eq!(tasks[1].priority, Priority::Medium);
}

#[test]
fn trello_board_json() {
    let d = device();
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("board.json");
    std::fs::write(
        &file,
        r#"{"name":"Launch","lists":[{"id":"l1","name":"To do","closed":false,"pos":1},{"id":"l2","name":"Old","closed":true,"pos":2}],
            "labels":[{"id":"lb1","name":"urgent","color":"red"},{"id":"lb2","name":"","color":"green"}],
            "cards":[{"id":"c1","name":"Ship it","desc":"All of it","closed":false,"idList":"l1","idLabels":["lb1","lb2"],"due":"2026-10-09T09:00:00.000Z","dueComplete":false},
                     {"id":"c2","name":"Archived","desc":"","closed":true,"idList":"l1","idLabels":[]},
                     {"id":"c3","name":"In old list","desc":"","closed":false,"idList":"l2","idLabels":[]}],
            "checklists":[{"id":"k1","idCard":"c1","name":"Steps","checkItems":[{"id":"i2","name":"Second","state":"incomplete","pos":2},{"id":"i1","name":"First","state":"complete","pos":1}]}]}"#,
    )
    .unwrap();
    let report = d.import_file(file.to_string_lossy().into_owned()).unwrap();
    assert_eq!((report.source.as_str(), report.lists, report.tasks), ("Trello", 1, 3));
    assert!(report.notes.iter().any(|n| n.starts_with("2 archived cards")));

    let list = d
        .lists()
        .unwrap()
        .into_iter()
        .find(|l| l.name == "Launch: To do")
        .unwrap();
    let cards = d.tasks(Scope::List { id: list.id }).unwrap();
    assert_eq!(titles(&cards), ["Ship it"]);
    assert_eq!(cards[0].notes, "All of it");
    assert_eq!(cards[0].tags, ["green", "urgent"]);
    assert!(cards[0].due.as_deref().unwrap().starts_with("2026-10-09T"));
    let items = d.subtasks(cards[0].id.clone()).unwrap();
    assert_eq!(titles(&items), ["First", "Second"], "checklist order follows pos");
    assert!(items[0].done.is_some() && items[1].done.is_none());
}

#[test]
fn microsoft_to_do_lists_json() {
    let d = device();
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("todo.json");
    std::fs::write(
        &file,
        r#"[{"id":"L0","displayName":"Tasks","wellknownListName":"defaultList","tasks":[
               {"id":"a","title":"Pay rent","importance":"high","status":"notStarted","body":{"content":"by card","contentType":"text"},
                "dueDateTime":{"dateTime":"2026-10-10T00:00:00.0000000","timeZone":"UTC"},"categories":["Money"],
                "recurrence":{"pattern":{"type":"absoluteMonthly","interval":1,"dayOfMonth":10}},
                "checklistItems":[{"id":"x","displayName":"Check the amount","isChecked":true}]}]},
            {"id":"L1","displayName":"Shopping","wellKnownListName":"none","tasks":[
               {"id":"b","title":"Milk","importance":"normal","status":"completed","completedDateTime":{"dateTime":"2026-10-01T08:00:00.0000000","timeZone":"UTC"}},
               {"id":"c","title":"Odd repeat","importance":"low","status":"notStarted","recurrence":{"pattern":{"type":"relativeMonthly","interval":1}}}]}]"#,
    )
    .unwrap();
    let report = d.import_file(file.to_string_lossy().into_owned()).unwrap();
    assert_eq!(
        (report.source.as_str(), report.lists, report.tasks),
        ("Microsoft To Do", 1, 4)
    );
    assert!(report
        .notes
        .iter()
        .any(|n| n.starts_with("1 tasks repeat on a relative pattern")));

    let rent = &d.tasks(Scope::Inbox).unwrap()[0];
    assert_eq!(
        (rent.title.as_str(), rent.priority, rent.due.as_deref()),
        ("Pay rent", Priority::High, Some("2026-10-10"))
    );
    assert_eq!(
        (rent.notes.as_str(), rent.tags.clone()),
        ("by card", vec!["money".to_string()])
    );
    let repeat = rent.repeat.clone().unwrap();
    assert_eq!((repeat.freq, repeat.monthday), (Freq::Monthly, Some(10)));
    assert!(d.subtasks(rent.id.clone()).unwrap()[0].done.is_some());

    let shopping = d.lists().unwrap().into_iter().find(|l| l.name == "Shopping").unwrap();
    assert_eq!(
        view(&d, Scope::List { id: shopping.id }),
        ["Odd repeat"],
        "the completed one is in Completed"
    );
    assert_eq!(view(&d, Scope::Completed), ["Milk"]);
}

#[test]
fn unknown_files_are_refused_with_a_reason() {
    let d = device();
    let dir = tempfile::tempdir().unwrap();
    let csv = dir.path().join("x.csv");
    std::fs::write(&csv, "a,b\n1,2\n").unwrap();
    assert!(d
        .import_file(csv.to_string_lossy().into_owned())
        .unwrap_err()
        .to_string()
        .contains("Todoist"));
    let json = dir.path().join("x.json");
    std::fs::write(&json, "{\"hello\":1}").unwrap();
    assert!(d.import_file(json.to_string_lossy().into_owned()).is_err());
    let zip = dir.path().join("x.2dodb");
    std::fs::write(&zip, b"PK not really").unwrap();
    assert!(d.import_file(zip.to_string_lossy().into_owned()).is_err());
    assert!(view(&d, Scope::Inbox).is_empty());
}

#[test]
fn i8_twodo_attachment_gets_the_extension_kept_beside_its_name() {
    let d = device();
    let dir = tempfile::tempdir().unwrap();
    d.import_file(twodo_backup(dir.path())).unwrap();
    let all = d.tasks(Scope::All).unwrap();
    let files = |title: &str| {
        let task = all.iter().find(|t| t.title == title).unwrap();
        d.attachments(task.id.clone()).unwrap()
    };
    // 2Do names a photo "Image" and keeps "jpg" in a column of its own.
    let photo = files("Полить цветы");
    assert_eq!(
        (photo[0].name.as_str(), photo[0].mime.as_str()),
        ("Image.jpg", "image/jpeg")
    );
    // A name that already ends with the extension is left as it is.
    let plan = files("Ремонт");
    assert_eq!(plan[0].name, "План.jpg");
}
