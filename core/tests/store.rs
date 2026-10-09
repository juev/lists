//! Behaviour of lists, tasks, subtasks and recurrence: docs/specs/product.md.

mod common;

use common::*;
use lists_core::*;

fn weekly() -> Repeat {
    Repeat {
        freq: Freq::Weekly,
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
fn r1_inbox_always_exists_and_cannot_be_removed() {
    let d = device();
    let lists = d.lists().unwrap();
    assert_eq!(lists.len(), 1);
    assert_eq!(lists[0].id, INBOX_ID);
    assert!(d.delete_list(INBOX_ID.into()).is_err());
    assert!(d.set_list_archived(INBOX_ID.into(), true).is_err());

    add(&d, "без списка");
    assert_eq!(view(&d, Scope::Inbox), ["без списка"]);
}

#[test]
fn r2_list_settings_are_stored_and_applied() {
    let d = device();
    let list = d.create_list("Работа".into()).unwrap();
    d.set_list_color(list.id.clone(), "#3478F6".into()).unwrap();
    d.set_list_icon(list.id.clone(), "briefcase".into()).unwrap();
    d.set_list_defaults(list.id.clone(), Priority::High, true).unwrap();

    let got = d.list(list.id.clone()).unwrap();
    assert_eq!((got.color.as_str(), got.icon.as_str()), ("#3478F6", "briefcase"));

    let in_list = |title: &str| NewTask {
        title: title.into(),
        list_id: Some(list.id.clone()),
        ..NewTask::default()
    };
    let b = d.create_task(in_list("b")).unwrap();
    assert_eq!(b.priority, Priority::High, "list default priority");
    assert_eq!(b.due.as_deref(), Some("2026-10-05"), "list default due");
    let a = d
        .create_task(NewTask {
            priority: Some(Priority::Low),
            due: Some("2026-10-01".into()),
            ..in_list("a")
        })
        .unwrap();
    assert_eq!(a.priority, Priority::Low, "explicit value wins over the default");

    let of = |d: &Device| view(d, Scope::List { id: list.id.clone() });
    assert_eq!(of(&d), ["b", "a"], "manual order is creation order");
    d.set_list_sort(list.id.clone(), SortMode::Title).unwrap();
    assert_eq!(of(&d), ["a", "b"]);
    d.set_list_sort(list.id.clone(), SortMode::Priority).unwrap();
    assert_eq!(of(&d), ["b", "a"]);
    d.set_list_sort(list.id.clone(), SortMode::Due).unwrap();
    assert_eq!(of(&d), ["a", "b"]);

    d.complete_task(a.id).unwrap();
    // A task completed a moment ago stays where it was (R68); this is about the time after that.
    d.set_now_for_tests("2026-10-05T10:30");
    assert_eq!(of(&d), ["b"]);
    d.set_list_show_done(list.id.clone(), true).unwrap();
    assert_eq!(of(&d), ["b", "a"], "completed tasks go last");
    d.set_list_show_done(list.id.clone(), false).unwrap();
    assert_eq!(of(&d), ["b"], "switched off, completed tasks leave the list again");
    assert_eq!(d.list(list.id).unwrap().open_count, 1);
}

#[test]
fn r3_lists_are_reordered_archived_and_deleted() {
    let d = device();
    let a = d.create_list("A".into()).unwrap();
    let b = d.create_list("B".into()).unwrap();
    let c = d.create_list("C".into()).unwrap();
    let names = |d: &Device| d.lists().unwrap().into_iter().map(|l| l.name).collect::<Vec<_>>();
    assert_eq!(names(&d)[1..], ["A", "B", "C"]);
    d.move_list(c.id.clone(), None).unwrap();
    assert_eq!(names(&d)[1..], ["C", "A", "B"]);
    d.move_list(c.id.clone(), Some(a.id.clone())).unwrap();
    assert_eq!(names(&d)[1..], ["A", "C", "B"]);

    let task = d
        .create_task(NewTask {
            title: "в B".into(),
            list_id: Some(b.id.clone()),
            due: Some("2026-10-05".into()),
            ..NewTask::default()
        })
        .unwrap();
    d.set_list_archived(b.id.clone(), true).unwrap();
    assert!(view(&d, Scope::Today).is_empty(), "archived lists stay out of Today");
    d.set_list_archived(b.id.clone(), false).unwrap();
    assert_eq!(view(&d, Scope::Today), ["в B"]);

    d.delete_list(b.id.clone()).unwrap();
    assert_eq!(names(&d)[1..], ["A", "C"]);
    assert_eq!(view(&d, Scope::Trash), ["в B"]);
    // S6: restored without its list, the task shows up in the inbox.
    d.restore_task(task.id).unwrap();
    assert_eq!(view(&d, Scope::Inbox), ["в B"]);
}

#[test]
fn r4_fields_round_trip() {
    let d = device();
    let t = add(&d, "  задача  ");
    assert_eq!(t.title, "задача");
    assert!(d
        .create_task(NewTask {
            title: "   ".into(),
            ..NewTask::default()
        })
        .is_err());

    d.set_notes(t.id.clone(), "заметка".into()).unwrap();
    d.set_start(t.id.clone(), Some("2026-10-06".into())).unwrap();
    d.set_due(t.id.clone(), Some("2026-10-07T09:30".into())).unwrap();
    d.set_priority(t.id.clone(), Priority::Medium).unwrap();
    d.set_remind(t.id.clone(), Some("2026-10-07T09:00".into())).unwrap();
    d.add_tag(t.id.clone(), "#Дом".into()).unwrap();
    d.add_tag(t.id.clone(), "срочно".into()).unwrap();
    d.remove_tag(t.id.clone(), "срочно".into()).unwrap();

    let got = d.task(t.id.clone()).unwrap();
    assert_eq!(got.notes, "заметка");
    assert_eq!(got.start.as_deref(), Some("2026-10-06"));
    assert_eq!(got.due.as_deref(), Some("2026-10-07T09:30"));
    assert_eq!(got.priority, Priority::Medium);
    assert_eq!(got.remind.as_deref(), Some("2026-10-07T09:00"));
    assert_eq!(got.tags, ["дом"]);

    assert!(d.set_due(t.id.clone(), Some("завтра".into())).is_err());
    assert!(d.set_due(t.id.clone(), Some("2026-13-40".into())).is_err());
    d.set_due(t.id.clone(), None).unwrap();
    assert_eq!(d.task(t.id).unwrap().due, None);
}

#[test]
fn r5_start_date_hides_the_task_from_today() {
    let d = device();
    let t = add(&d, "позже");
    d.set_start(t.id.clone(), Some("2026-10-06".into())).unwrap();
    assert!(view(&d, Scope::Today).is_empty());
    assert_eq!(view(&d, Scope::Upcoming), ["позже"]);

    d.set_start(t.id.clone(), Some("2026-10-05".into())).unwrap();
    assert_eq!(view(&d, Scope::Today), ["позже"]);
    assert!(view(&d, Scope::Upcoming).is_empty());

    // Due today but not startable until tomorrow: still hidden.
    d.set_due(t.id.clone(), Some("2026-10-05".into())).unwrap();
    d.set_start(t.id, Some("2026-10-06".into())).unwrap();
    assert!(view(&d, Scope::Today).is_empty());
}

#[test]
fn r7_tags_list_only_those_in_use() {
    let d = device();
    let a = add(&d, "a");
    let b = add(&d, "b");
    d.add_tag(a.id.clone(), "дом".into()).unwrap();
    d.add_tag(b.id.clone(), "дом".into()).unwrap();
    d.add_tag(b.id.clone(), "офис".into()).unwrap();
    let tags = |d: &Device| {
        d.tags()
            .unwrap()
            .into_iter()
            .map(|t| (t.name, t.open_count))
            .collect::<Vec<_>>()
    };
    assert_eq!(tags(&d), [("дом".to_string(), 2), ("офис".to_string(), 1)]);
    assert_eq!(view(&d, Scope::Tag { name: "Дом".into() }), ["a", "b"]);

    d.complete_task(b.id).unwrap();
    assert_eq!(tags(&d), [("дом".to_string(), 1)]);
    assert!(d.add_tag(a.id, "два слова".into()).is_err());
}

#[test]
fn r9_trash_restore_and_purge() {
    let d = device();
    let t = add(&d, "мусор");
    let sub = add_sub(&d, &t, "часть");
    d.set_due(sub.id.clone(), Some("2026-10-05".into())).unwrap();
    assert_eq!(view(&d, Scope::Today), ["часть"]);

    d.delete_task(t.id.clone()).unwrap();
    assert!(view(&d, Scope::Inbox).is_empty());
    assert!(
        view(&d, Scope::Today).is_empty(),
        "subtasks of a deleted task are hidden too"
    );
    assert_eq!(view(&d, Scope::Trash), ["мусор"]);
    assert_eq!(d.counts().unwrap().trash, 1);

    d.restore_task(t.id.clone()).unwrap();
    assert_eq!(view(&d, Scope::Inbox), ["мусор"]);
    assert_eq!(view(&d, Scope::Today), ["часть"]);

    d.delete_task(t.id.clone()).unwrap();
    assert_eq!(d.empty_trash().unwrap(), 1);
    assert!(view(&d, Scope::Trash).is_empty());
    assert!(d.task(t.id).is_err());
}

#[test]
fn r46_completed_is_cleared_in_whole_or_before_a_day() {
    let d = device();
    d.set_now_for_tests("2026-08-01T09:00");
    let old = add(&d, "давняя");
    add_sub(&d, &old, "её часть");
    d.complete_task(old.id.clone()).unwrap();
    d.set_now_for_tests("2026-08-01T10:00");
    let rep = add(&d, "зарядка");
    d.set_due(rep.id.clone(), Some("2026-08-01".into())).unwrap();
    d.set_repeat(rep.id.clone(), Some(weekly())).unwrap();
    d.complete_task(rep.id.clone()).unwrap();
    d.set_now_for_tests("2026-09-20T09:00");
    let mid = add(&d, "сентябрьская");
    d.complete_task(mid.id).unwrap();
    d.set_now_for_tests(NOW);
    let fresh = add(&d, "свежая");
    d.complete_task(fresh.id).unwrap();
    let open = add(&d, "в работе");
    let part = add_sub(&d, &open, "сделанная часть");
    d.complete_task(part.id.clone()).unwrap();
    let binned = add(&d, "в корзине");
    d.complete_task(binned.id.clone()).unwrap();
    d.delete_task(binned.id.clone()).unwrap();
    assert_eq!(
        view(&d, Scope::Completed),
        ["свежая", "сентябрьская", "зарядка", "давняя"]
    );

    assert!(d.clear_completed(Some("в августе".into())).is_err());
    assert!(
        d.clear_completed(Some(String::new())).is_err(),
        "an empty day does not mean everything"
    );
    assert_eq!(
        d.clear_completed(Some("2026-08-01".into())).unwrap(),
        0,
        "the day itself is kept"
    );
    assert_eq!(d.clear_completed(Some("2026-09-05".into())).unwrap(), 2);
    assert_eq!(view(&d, Scope::Completed), ["свежая", "сентябрьская"]);
    assert!(d.task(old.id).is_err(), "cleared for good, not moved to the trash");
    assert!(
        view(
            &d,
            Scope::Search {
                text: "её часть".into()
            }
        )
        .is_empty(),
        "subtasks go with their task"
    );
    assert!(
        d.task(rep.id.clone()).unwrap().done.is_none(),
        "the repeating task itself stays"
    );
    assert_eq!(view(&d, Scope::Trash), ["в корзине"]);

    assert_eq!(d.clear_completed(None).unwrap(), 2);
    assert!(view(&d, Scope::Completed).is_empty());
    assert_eq!(view(&d, Scope::Inbox), ["зарядка", "в работе"]);
    assert!(
        d.task(part.id).unwrap().done.is_some(),
        "a completed subtask of an open task stays"
    );
    assert_eq!(view(&d, Scope::Trash), ["в корзине"]);
    d.restore_task(binned.id).unwrap();
    assert_eq!(view(&d, Scope::Completed), ["в корзине"], "the trash was not cleared");
}

#[test]
fn r46_completed_lists_the_whole_log() {
    let d = device();
    let t = add(&d, "зарядка");
    d.set_due(t.id.clone(), Some("2026-10-05".into())).unwrap();
    let mut daily = weekly();
    daily.freq = Freq::Daily;
    d.set_repeat(t.id.clone(), Some(daily)).unwrap();
    for _ in 0..501 {
        d.complete_task(t.id.clone()).unwrap();
    }
    assert_eq!(d.tasks(Scope::Completed).unwrap().len(), 501);
}

#[test]
fn r10_subtasks_carry_every_field_and_nest() {
    let d = device();
    let top = add(&d, "проект");
    let sub = add_sub(&d, &top, "этап");
    let deep = add_sub(&d, &sub, "шаг");
    d.set_due(deep.id.clone(), Some("2026-10-09".into())).unwrap();
    d.set_priority(deep.id.clone(), Priority::High).unwrap();
    d.set_repeat(deep.id.clone(), Some(weekly())).unwrap();
    d.add_tag(deep.id.clone(), "глубоко".into()).unwrap();

    let got = d.task(deep.id).unwrap();
    assert_eq!(got.parent_id.as_deref(), Some(sub.id.as_str()));
    assert_eq!(got.parent_title.as_deref(), Some("этап"));
    assert_eq!((got.priority, got.due.as_deref()), (Priority::High, Some("2026-10-09")));
    assert!(got.repeat.is_some());
    assert_eq!(got.tags, ["глубоко"]);

    assert_eq!(view(&d, Scope::Inbox), ["проект"], "only top-level tasks in a list");
    assert_eq!(titles(&d.subtasks(top.id.clone()).unwrap()), ["этап"]);
    assert_eq!(d.task(top.id).unwrap().subtasks_total, 1);
}

#[test]
fn r11_completing_a_task_completes_its_open_subtasks() {
    let d = device();
    let top = add(&d, "родитель");
    let a = add_sub(&d, &top, "a");
    let b = add_sub(&d, &top, "b");
    let deep = add_sub(&d, &b, "deep");

    d.complete_task(top.id.clone()).unwrap();
    for id in [&a.id, &b.id, &deep.id] {
        assert!(d.task(id.clone()).unwrap().done.is_some());
    }
    assert_eq!(d.task(top.id.clone()).unwrap().subtasks_done, 2);
    assert_eq!(view(&d, Scope::Completed), ["родитель"]);

    // Reopening the parent leaves the subtasks alone.
    d.reopen_task(top.id.clone()).unwrap();
    assert!(d.task(top.id).unwrap().done.is_none());
    assert!(d.task(a.id).unwrap().done.is_some());
}

#[test]
fn r12_dated_subtask_shows_up_on_its_own_with_parent_title() {
    let d = device();
    let top = add(&d, "поездка");
    let sub = add_sub(&d, &top, "билеты");
    d.set_due(sub.id, Some("2026-10-05".into())).unwrap();
    let today = d.tasks(Scope::Today).unwrap();
    assert_eq!(titles(&today), ["билеты"]);
    assert_eq!(today[0].parent_title.as_deref(), Some("поездка"));
}

#[test]
fn r13_moving_between_parents_and_lists() {
    let d = device();
    let list = d.create_list("Дом".into()).unwrap();
    let a = add(&d, "A");
    let b = add_sub(&d, &a, "B");
    let c = add_sub(&d, &b, "C");

    // A task cannot become its own descendant.
    assert!(d.move_task(a.id.clone(), None, Some(b.id.clone()), None).is_err());
    assert!(d.move_task(a.id.clone(), None, Some(c.id.clone()), None).is_err());
    assert!(d.move_task(a.id.clone(), None, Some(a.id.clone()), None).is_err());

    // Subtask becomes a top-level task of another list and takes its subtree along.
    d.move_task(b.id.clone(), Some(list.id.clone()), None, None).unwrap();
    assert_eq!(view(&d, Scope::List { id: list.id.clone() }), ["B"]);
    assert_eq!(d.task(c.id.clone()).unwrap().list_id, list.id);
    assert_eq!(d.task(a.id.clone()).unwrap().subtasks_total, 0);

    // And back under A.
    d.move_task(b.id.clone(), None, Some(a.id.clone()), None).unwrap();
    assert_eq!(d.task(c.id).unwrap().list_id, INBOX_ID);
    assert_eq!(titles(&d.subtasks(a.id.clone()).unwrap()), ["B"]);

    d.move_to_list(a.id, list.id.clone()).unwrap();
    assert_eq!(d.task(b.id).unwrap().list_id, list.id);
}

#[test]
fn manual_order_within_a_list() {
    let d = device();
    let a = add(&d, "a");
    let b = add(&d, "b");
    let c = add(&d, "c");
    assert_eq!(view(&d, Scope::Inbox), ["a", "b", "c"]);
    d.move_task(c.id.clone(), None, None, None).unwrap();
    assert_eq!(view(&d, Scope::Inbox), ["c", "a", "b"]);
    d.move_task(c.id.clone(), None, None, Some(a.id.clone())).unwrap();
    assert_eq!(view(&d, Scope::Inbox), ["a", "c", "b"]);
    d.move_task(a.id, None, None, Some(b.id)).unwrap();
    assert_eq!(view(&d, Scope::Inbox), ["c", "b", "a"]);
}

#[test]
fn r17_completing_a_repeating_task_moves_it_forward() {
    let d = device();
    let t = add(&d, "полить цветы");
    d.set_start(t.id.clone(), Some("2026-10-03".into())).unwrap();
    d.set_due(t.id.clone(), Some("2026-10-05T19:00".into())).unwrap();
    d.set_remind(t.id.clone(), Some("2026-10-05T18:45".into())).unwrap();
    d.set_repeat(t.id.clone(), Some(weekly())).unwrap();
    let sub = add_sub(&d, &t, "набрать воды");
    d.complete_task(sub.id.clone()).unwrap();

    let after = d.complete_task(t.id.clone()).unwrap();
    assert!(after.done.is_none(), "the task stays open");
    assert_eq!(after.due.as_deref(), Some("2026-10-12T19:00"));
    assert_eq!(after.start.as_deref(), Some("2026-10-10"));
    assert_eq!(after.remind.as_deref(), Some("2026-10-12T18:45"));
    assert!(
        d.task(sub.id).unwrap().done.is_none(),
        "subtasks are reopened for the next round"
    );

    let log = d.tasks(Scope::Completed).unwrap();
    assert_eq!(titles(&log), ["полить цветы"]);
    assert!(log[0].is_log);
    assert_eq!(log[0].due.as_deref(), Some("2026-10-05T19:00"));
    assert!(d.reopen_task(log[0].id.clone()).is_err());
    assert_eq!(
        view(&d, Scope::Inbox),
        ["полить цветы"],
        "the record is not a task of the list"
    );
}

#[test]
fn r17_last_occurrence_completes_the_task() {
    let d = device();
    let t = add(&d, "курс");
    d.set_due(t.id.clone(), Some("2026-10-05".into())).unwrap();
    d.set_repeat(
        t.id.clone(),
        Some(Repeat {
            freq: Freq::Daily,
            count: Some(2),
            ..weekly()
        }),
    )
    .unwrap();

    let first = d.complete_task(t.id.clone()).unwrap();
    assert!(first.done.is_none());
    assert_eq!(first.due.as_deref(), Some("2026-10-06"));
    assert_eq!(first.repeat.unwrap().count, Some(1));

    d.set_now_for_tests("2026-10-06T10:00");
    let second = d.complete_task(t.id).unwrap();
    assert!(second.done.is_some());
    assert_eq!(d.tasks(Scope::Completed).unwrap().len(), 2);
}

#[test]
fn r18_monthly_on_the_31st() {
    let d = device();
    d.set_now_for_tests("2026-01-31T10:00");
    let t = add(&d, "отчёт");
    d.set_due(t.id.clone(), Some("2026-01-31".into())).unwrap();
    d.set_repeat(
        t.id.clone(),
        Some(Repeat {
            freq: Freq::Monthly,
            ..weekly()
        }),
    )
    .unwrap();
    assert_eq!(
        d.complete_task(t.id.clone()).unwrap().due.as_deref(),
        Some("2026-02-28")
    );
    d.set_now_for_tests("2026-02-28T10:00");
    assert_eq!(d.complete_task(t.id).unwrap().due.as_deref(), Some("2026-03-31"));
}

#[test]
fn repeating_task_without_dates_gets_a_due_date() {
    let d = device();
    let t = add(&d, "зарядка");
    d.set_repeat(
        t.id.clone(),
        Some(Repeat {
            freq: Freq::Daily,
            ..weekly()
        }),
    )
    .unwrap();
    assert_eq!(d.complete_task(t.id).unwrap().due.as_deref(), Some("2026-10-06"));
}

#[test]
fn r19_attachments_are_stored_by_content() {
    let d = device();
    let t = add(&d, "с файлом");
    let src = tempfile::tempdir().unwrap();
    let file = src.path().join("Счёт.pdf");
    std::fs::write(&file, b"%PDF-1.7 demo").unwrap();

    let a = d
        .add_attachment(t.id.clone(), file.to_string_lossy().into_owned(), None)
        .unwrap();
    assert_eq!(
        (a.name.as_str(), a.mime.as_str(), a.size),
        ("Счёт.pdf", "application/pdf", 13)
    );
    std::fs::remove_file(&file).unwrap();
    let stored = a.local_path.expect("content is kept by the store");
    assert_eq!(std::fs::read(stored).unwrap(), b"%PDF-1.7 demo");
    assert_eq!(d.task(t.id.clone()).unwrap().attachments, 1);

    let copy = d.duplicate_task(t.id.clone()).unwrap();
    assert_eq!(d.attachments(copy.id).unwrap().len(), 1);

    d.remove_attachment(a.id).unwrap();
    assert!(d.attachments(t.id).unwrap().is_empty());
}

#[test]
fn r21_smart_views_and_counts() {
    let d = device();
    let overdue = add(&d, "просрочено");
    d.set_due(overdue.id, Some("2026-10-01".into())).unwrap();
    let today = add(&d, "сегодня");
    d.set_due(today.id, Some("2026-10-05T23:00".into())).unwrap();
    let later = add(&d, "потом");
    d.set_due(later.id, Some("2026-10-20".into())).unwrap();
    let sooner = add(&d, "скоро");
    d.set_due(sooner.id, Some("2026-10-06".into())).unwrap();
    add(&d, "без даты");

    assert_eq!(view(&d, Scope::Today), ["просрочено", "сегодня"]);
    assert_eq!(view(&d, Scope::Upcoming), ["скоро", "потом"]);
    assert_eq!(view(&d, Scope::All).len(), 5);
    let c = d.counts().unwrap();
    assert_eq!((c.inbox, c.today, c.overdue, c.upcoming, c.trash), (5, 2, 1, 2, 0));
}

#[test]
fn r93_counts_say_which_built_in_views_hold_something() {
    let d = device();
    let c = d.counts().unwrap();
    assert_eq!((c.all, c.completed, c.wont_do, c.trash), (0, 0, 0, 0));

    let parent = add(&d, "открытая");
    add_sub(&d, &parent, "подзадача");
    let done = add(&d, "сделанная");
    d.complete_task(done.id).unwrap();
    let dropped = add(&d, "не буду");
    d.wont_do_task(dropped.id.clone()).unwrap();
    let gone = add(&d, "удалённая");
    d.delete_task(gone.id).unwrap();

    let c = d.counts().unwrap();
    // A subtask is not a row of All; "won't do" is a row of Completed as well.
    assert_eq!((c.all, c.completed, c.wont_do, c.trash), (1, 2, 1, 1));
    assert_eq!(c.completed as usize, view(&d, Scope::Completed).len());
    assert_eq!(c.wont_do as usize, view(&d, Scope::WontDo).len());

    d.reopen_task(dropped.id).unwrap();
    let c = d.counts().unwrap();
    assert_eq!((c.all, c.completed, c.wont_do), (2, 1, 0));
}

#[test]
fn r22_search_ignores_case_in_any_script() {
    let d = device();
    let t = add(&d, "Купить МОЛОКО");
    d.set_notes(t.id, "в Перекрёстке".into()).unwrap();
    add(&d, "другое");
    assert_eq!(
        view(
            &d,
            Scope::Search {
                text: "молоко".into()
            }
        ),
        ["Купить МОЛОКО"]
    );
    assert_eq!(
        view(
            &d,
            Scope::Search {
                text: "ПЕРЕКРЁСТКЕ".into()
            }
        ),
        ["Купить МОЛОКО"]
    );
    assert!(view(&d, Scope::Search { text: "  ".into() }).is_empty());
}

#[test]
fn r23_quick_add_creates_the_task_the_line_describes() {
    let d = device();
    let shop = d.create_list("Покупки".into()).unwrap();
    let t = d
        .quick_add("купить молоко завтра 18:30 !! #дом @покупки".into(), None)
        .unwrap();
    assert_eq!(t.title, "купить молоко");
    assert_eq!(t.due.as_deref(), Some("2026-10-06T18:30"));
    assert_eq!(t.priority, Priority::Medium);
    assert_eq!(t.tags, ["дом"]);
    assert_eq!(t.list_id, shop.id);

    // An unknown @word is not a list: it stays in the title, the fallback list is used.
    let other = d.quick_add("написать @ivan".into(), Some(shop.id.clone())).unwrap();
    assert_eq!(other.title, "написать @ivan");
    assert_eq!(other.list_id, shop.id);

    assert!(d.quick_add("#тег !!".into(), None).is_err(), "a title is required");
}

#[test]
fn duplicate_copies_the_subtree_next_to_the_original() {
    let d = device();
    let a = add(&d, "a");
    add(&d, "z");
    let sub = add_sub(&d, &a, "sub");
    add_sub(&d, &sub, "deep");
    d.set_repeat(a.id.clone(), Some(weekly())).unwrap();

    let copy = d.duplicate_task(a.id).unwrap();
    assert_eq!(view(&d, Scope::Inbox), ["a", "a", "z"]);
    assert!(copy.repeat.is_some());
    let copied_sub = d.subtasks(copy.id).unwrap();
    assert_eq!(titles(&copied_sub), ["sub"]);
    assert_eq!(titles(&d.subtasks(copied_sub[0].id.clone()).unwrap()), ["deep"]);
}

#[test]
fn data_survives_reopening() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().to_string_lossy().into_owned();
    let id = {
        let store = Store::open(path.clone()).unwrap();
        store
            .create_task(NewTask {
                title: "помнить".into(),
                ..NewTask::default()
            })
            .unwrap()
            .id
    };
    let store = Store::open(path).unwrap();
    assert_eq!(store.task(id.clone()).unwrap().title, "помнить");
    // The clock continues past what is stored, so a new edit wins over the old value.
    store.set_title(id.clone(), "помнить всё".into()).unwrap();
    assert_eq!(store.task(id).unwrap().title, "помнить всё");
}

#[test]
fn r8_reminders_list_open_tasks_in_time_order() {
    let d = device();
    let late = add(&d, "поздно");
    d.set_remind(late.id, Some("2026-10-07T09:00".into())).unwrap();
    let early = add(&d, "рано");
    d.set_remind(early.id.clone(), Some("2026-10-06T08:00".into())).unwrap();
    let done = add(&d, "уже сделано");
    d.set_remind(done.id.clone(), Some("2026-10-06T07:00".into())).unwrap();
    d.complete_task(done.id).unwrap();
    add(&d, "без напоминания");

    assert_eq!(titles(&d.reminders().unwrap()), ["рано", "поздно"]);
    d.delete_task(early.id).unwrap();
    assert_eq!(titles(&d.reminders().unwrap()), ["поздно"]);
}

#[test]
fn projects_are_tasks_with_a_view_of_their_own() {
    let d = device();
    let work = d.create_list("Работа".into()).unwrap();
    let launch = d
        .create_task(NewTask {
            title: "Запуск сайта".into(),
            list_id: Some(work.id.clone()),
            ..NewTask::default()
        })
        .unwrap();
    add(&d, "обычная задача");
    assert!(d.projects().unwrap().is_empty());

    d.set_project(launch.id.clone(), true).unwrap();
    let design = d
        .quick_add_under("Макеты завтра !! #дизайн".into(), launch.id.clone())
        .unwrap();
    assert_eq!(
        (design.title.as_str(), design.due.as_deref(), design.priority),
        ("Макеты", Some("2026-10-06"), Priority::Medium)
    );
    assert_eq!(
        design.list_id, work.id,
        "a task of a project lives in the project's list"
    );
    let copy = add_sub(&d, &launch, "Тексты");
    d.complete_task(copy.id).unwrap();

    let projects = d.projects().unwrap();
    assert_eq!(titles(&projects), ["Запуск сайта"]);
    assert!(projects[0].is_project);
    assert_eq!((projects[0].subtasks_total, projects[0].subtasks_done), (2, 1));
    assert_eq!(
        view(&d, Scope::Project { id: launch.id.clone() }),
        ["Макеты", "Тексты"],
        "open first, completed last"
    );
    assert_eq!(
        view(&d, Scope::Upcoming),
        ["Макеты"],
        "project tasks show up in the date views"
    );

    // A subtask cannot be a project; turning a project back keeps its tasks.
    assert!(d.set_project(design.id, true).is_err());
    d.set_project(launch.id.clone(), false).unwrap();
    assert!(d.projects().unwrap().is_empty());
    assert_eq!(d.subtasks(launch.id.clone()).unwrap().len(), 2);

    // A completed project leaves the sidebar.
    d.set_project(launch.id.clone(), true).unwrap();
    d.complete_task(launch.id).unwrap();
    assert!(d.projects().unwrap().is_empty());
}

fn spec() -> FilterSpec {
    FilterSpec::default()
}

#[test]
fn saved_filters_select_by_date_list_tag_priority_status_and_text() {
    let d = device();
    let work = d.create_list("Работа".into()).unwrap();
    let mk = |title: &str, due: Option<&str>, list: Option<&str>| {
        d.create_task(NewTask {
            title: title.into(),
            due: due.map(str::to_string),
            list_id: list.map(str::to_string),
            ..NewTask::default()
        })
        .unwrap()
    };
    let late = mk("просрочено", Some("2026-10-01"), None);
    mk("сегодня", Some("2026-10-05T18:00"), Some(&work.id));
    let soon = mk("через три дня", Some("2026-10-08"), Some(&work.id));
    mk("через неделю", Some("2026-10-12"), None);
    mk("без даты", None, Some(&work.id));
    let done = mk("сделано", Some("2026-10-05"), None);
    d.complete_task(done.id).unwrap();
    // Past the time a completed task stays among the open ones (R68).
    d.set_now_for_tests("2026-10-05T10:30");
    d.add_tag(soon.id.clone(), "важное".into()).unwrap();
    d.set_priority(soon.id.clone(), Priority::High).unwrap();
    d.set_priority(late.id, Priority::Low).unwrap();
    d.set_notes(soon.id, "позвонить Ивану".into()).unwrap();

    let show = |s: FilterSpec| {
        titles(&d.preview_filter(s).unwrap())
            .into_iter()
            .map(str::to_string)
            .collect::<Vec<_>>()
    };
    assert_eq!(
        show(FilterSpec {
            due: DueWindow::Next { days: 7 },
            ..spec()
        }),
        ["просрочено", "сегодня", "через три дня"]
    );
    assert_eq!(
        show(FilterSpec {
            due: DueWindow::Next { days: 8 },
            ..spec()
        })
        .len(),
        4,
        "the eighth day is the 12th"
    );
    assert_eq!(
        show(FilterSpec {
            due: DueWindow::Today,
            ..spec()
        }),
        ["сегодня"]
    );
    assert_eq!(
        show(FilterSpec {
            due: DueWindow::Overdue,
            ..spec()
        }),
        ["просрочено"]
    );
    assert_eq!(
        show(FilterSpec {
            due: DueWindow::NoDate,
            ..spec()
        }),
        ["без даты"]
    );
    assert_eq!(
        show(FilterSpec {
            list_ids: vec![work.id.clone()],
            ..spec()
        }),
        ["сегодня", "через три дня", "без даты"]
    );
    assert_eq!(
        show(FilterSpec {
            tags: vec!["#Важное".into()],
            ..spec()
        }),
        ["через три дня"]
    );
    assert_eq!(
        show(FilterSpec {
            min_priority: Priority::Low,
            ..spec()
        }),
        ["просрочено", "через три дня"]
    );
    assert_eq!(
        show(FilterSpec {
            min_priority: Priority::High,
            ..spec()
        }),
        ["через три дня"]
    );
    assert_eq!(
        show(FilterSpec {
            status: FilterStatus::Done,
            ..spec()
        }),
        ["сделано"]
    );
    assert_eq!(
        show(FilterSpec {
            status: FilterStatus::All,
            due: DueWindow::Today,
            ..spec()
        }),
        ["сегодня", "сделано"]
    );
    assert_eq!(
        show(FilterSpec {
            text: "ИВАНУ позвонить".into(),
            ..spec()
        }),
        ["через три дня"]
    );
    assert_eq!(
        show(FilterSpec {
            due: DueWindow::Next { days: 7 },
            list_ids: vec![work.id],
            min_priority: Priority::Medium,
            ..spec()
        }),
        ["через три дня"]
    );
}

#[test]
fn saved_filters_are_named_stored_and_shown_as_views() {
    let d = device();
    add(&d, "без даты");
    let t = add(&d, "скоро");
    d.set_due(t.id, Some("2026-10-07".into())).unwrap();
    assert!(d.create_filter("  ".into(), spec()).is_err());

    let week = d
        .create_filter(
            "Неделя".into(),
            FilterSpec {
                due: DueWindow::Next { days: 7 },
                ..spec()
            },
        )
        .unwrap();
    assert_eq!((week.name.as_str(), week.open_count), ("Неделя", 1));
    assert_eq!(view(&d, Scope::Filter { id: week.id.clone() }), ["скоро"]);

    d.update_filter(
        week.id.clone(),
        "Без срока".into(),
        FilterSpec {
            due: DueWindow::NoDate,
            ..spec()
        },
    )
    .unwrap();
    let all = d.filters().unwrap();
    assert_eq!(all.len(), 1);
    assert_eq!(
        (all[0].name.as_str(), all[0].spec.due),
        ("Без срока", DueWindow::NoDate)
    );
    assert_eq!(view(&d, Scope::Filter { id: week.id.clone() }), ["без даты"]);

    d.delete_filter(week.id.clone()).unwrap();
    assert!(d.filters().unwrap().is_empty());
    assert!(d.tasks(Scope::Filter { id: week.id }).is_err());
}

#[test]
fn derived_tables_are_rebuilt_when_their_shape_changes() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().to_string_lossy().into_owned();
    let id = {
        let store = Store::open(path.clone()).unwrap();
        let t = store
            .create_task(NewTask {
                title: "переживёт".into(),
                ..NewTask::default()
            })
            .unwrap();
        store.add_tag(t.id.clone(), "тег".into()).unwrap();
        store.set_project(t.id.clone(), true).unwrap();
        t.id
    };
    // What an older version of the app left behind: derived tables of another shape.
    {
        let conn = rusqlite::Connection::open(dir.path().join("lists.sqlite")).unwrap();
        conn.execute_batch("DROP TABLE tasks; CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT); UPDATE meta SET value = '1' WHERE key = 'derived_version';").unwrap();
    }
    let store = Store::open(path).unwrap();
    let got = store.task(id).unwrap();
    assert_eq!((got.title.as_str(), got.is_project), ("переживёт", true));
    assert_eq!(got.tags, ["тег"]);
}

fn notify() -> NotifySettings {
    NotifySettings {
        enabled: true,
        lead_minutes: vec![15],
        all_day_at: Some("09:00".into()),
        summary_at: None,
    }
}

#[test]
fn notifications_follow_reminders_due_dates_and_settings() {
    let d = device(); // now is 2026-10-05T10:00
    let mk = |title: &str, due: Option<&str>, remind: Option<&str>| {
        let t = d
            .create_task(NewTask {
                title: title.into(),
                due: due.map(str::to_string),
                ..NewTask::default()
            })
            .unwrap();
        if let Some(r) = remind {
            d.set_remind(t.id.clone(), Some(r.into())).unwrap();
        }
        t
    };
    mk(
        "со своим напоминанием",
        Some("2026-10-06T18:00"),
        Some("2026-10-06T12:00"),
    );
    mk("срок со временем", Some("2026-10-05T18:30"), None);
    mk("срок на день", Some("2026-10-07"), None);
    mk("срок сегодня без времени", Some("2026-10-05"), None);
    mk("напоминание в прошлом", None, Some("2026-10-05T09:00"));
    let done = mk("выполнена", Some("2026-10-06T10:00"), None);
    d.complete_task(done.id).unwrap();
    mk("без дат", None, None);

    let plan = |s: NotifySettings| {
        d.planned_notifications(s)
            .unwrap()
            .into_iter()
            .map(|n| (n.title, n.at, n.kind))
            .collect::<Vec<_>>()
    };
    assert_eq!(
        plan(notify()),
        [
            ("срок со временем".to_string(), "2026-10-05T18:15".to_string(), NotificationKind::Due),
            ("со своим напоминанием".to_string(), "2026-10-06T12:00".to_string(), NotificationKind::Reminder),
            ("срок на день".to_string(), "2026-10-07T09:00".to_string(), NotificationKind::Due),
        ],
        "past moments, completed tasks and tasks without dates produce nothing; a reminder of its own replaces the derived one"
    );
    // Each kind of derived reminder can be turned off; a task's own reminder stays.
    assert_eq!(
        plan(NotifySettings {
            lead_minutes: vec![],
            all_day_at: None,
            ..notify()
        })
        .len(),
        1
    );
    assert_eq!(
        plan(NotifySettings {
            lead_minutes: vec![0],
            ..notify()
        })[0]
            .1,
        "2026-10-05T18:30"
    );
    assert!(plan(NotifySettings {
        enabled: false,
        ..notify()
    })
    .is_empty());
    // Several lead times give several notifications for one task; those already past are dropped.
    let several = d
        .planned_notifications(NotifySettings {
            lead_minutes: vec![60, 15, 15, 1440],
            all_day_at: None,
            ..notify()
        })
        .unwrap()
        .into_iter()
        .filter(|n| n.title == "срок со временем")
        .map(|n| (n.at, n.key.rsplit(':').next().unwrap_or_default().to_string()))
        .collect::<Vec<_>>();
    assert_eq!(
        several,
        [
            ("2026-10-05T17:30".to_string(), "60".to_string()),
            ("2026-10-05T18:15".to_string(), "15".to_string()),
        ]
    );

    let summary: Vec<(String, u32)> = d
        .planned_notifications(NotifySettings {
            lead_minutes: vec![],
            all_day_at: None,
            summary_at: Some("08:00".into()),
            ..notify()
        })
        .unwrap()
        .into_iter()
        .filter(|n| n.kind == NotificationKind::Summary)
        .map(|n| (n.at, n.count))
        .collect();
    assert_eq!(
        summary[0],
        ("2026-10-06T08:00".to_string(), 3),
        "today's eight o'clock has passed; tomorrow counts everything due by then"
    );
    assert_eq!(summary[1], ("2026-10-07T08:00".to_string(), 4));
    assert_eq!(summary.len(), 6);
}

fn due_today(d: &Device, title: &str) -> TaskItem {
    d.create_task(NewTask {
        title: title.into(),
        due: Some("2026-10-05".into()),
        ..NewTask::default()
    })
    .unwrap()
}

#[test]
fn r68_a_completed_task_stays_in_place_for_the_set_time() {
    let d = device();
    assert_eq!(
        d.keep_done().unwrap(),
        KeepDone::Seconds { seconds: 5 },
        "five seconds unless set"
    );
    due_today(&d, "а");
    let b = due_today(&d, "б");
    due_today(&d, "в");
    d.add_tag(b.id.clone(), "дом".into()).unwrap();
    let tag = || Scope::Tag { name: "дом".into() };

    d.complete_task(b.id.clone()).unwrap();
    d.set_now_for_tests("2026-10-05T10:00:04");
    for scope in [Scope::Today, Scope::Inbox, Scope::All] {
        let tasks = d.tasks(scope.clone()).unwrap();
        assert_eq!(titles(&tasks), ["а", "б", "в"], "{scope:?}: where it was");
        assert!(tasks[1].done.is_some(), "{scope:?}: shown as completed");
    }
    assert_eq!(view(&d, tag()), ["б"]);
    let counts = d.counts().unwrap();
    assert_eq!((counts.today, counts.inbox), (2, 2), "not counted as open");
    assert_eq!(d.tags().unwrap().len(), 0, "nor under its tag");

    // Completed at 10:00:00, kept through 10:00:05.
    d.set_now_for_tests("2026-10-05T10:00:05");
    assert_eq!(view(&d, Scope::Today), ["а", "б", "в"]);
    d.set_now_for_tests("2026-10-05T10:00:06");
    for scope in [Scope::Today, Scope::Inbox, Scope::All] {
        assert_eq!(view(&d, scope.clone()), ["а", "в"], "{scope:?}: gone after the time");
    }
    assert!(view(&d, tag()).is_empty());
    assert_eq!(view(&d, Scope::Completed), ["б"]);
}

#[test]
fn r68_reopening_a_kept_task_leaves_it_where_it_was() {
    let d = device();
    due_today(&d, "а");
    let b = due_today(&d, "б");
    due_today(&d, "в");
    d.complete_task(b.id.clone()).unwrap();
    d.reopen_task(b.id).unwrap();
    d.set_now_for_tests("2026-10-05T12:00");
    assert_eq!(view(&d, Scope::Today), ["а", "б", "в"]);
    assert_eq!(d.counts().unwrap().today, 3);
}

#[test]
fn r68_the_time_is_a_setting_and_zero_removes_at_once() {
    let d = device();
    due_today(&d, "а");
    let b = due_today(&d, "б");
    d.complete_task(b.id).unwrap();

    d.set_keep_done(KeepDone::Seconds { seconds: 0 }).unwrap();
    assert_eq!(d.keep_done().unwrap(), KeepDone::Seconds { seconds: 0 });
    assert_eq!(view(&d, Scope::Today), ["а"], "at once");

    d.set_keep_done(KeepDone::Seconds { seconds: 3600 }).unwrap();
    d.set_now_for_tests("2026-10-05T10:59");
    assert_eq!(
        view(&d, Scope::Today),
        ["а", "б"],
        "the setting applies to what is already completed"
    );
    d.set_now_for_tests("2026-10-05T11:01");
    assert_eq!(view(&d, Scope::Today), ["а"]);

    d.set_keep_done(KeepDone::Seconds { seconds: 6_000_000 }).unwrap();
    assert_eq!(
        d.keep_done().unwrap(),
        KeepDone::Seconds { seconds: 86_400 },
        "a day at most"
    );
    for choice in [
        KeepDone::Seconds { seconds: 5 },
        KeepDone::Seconds { seconds: 15 },
        KeepDone::EndOfDay,
    ] {
        d.set_keep_done(choice).unwrap();
        assert_eq!(d.keep_done().unwrap(), choice);
    }
}

#[test]
fn r68_until_the_end_of_the_day_keeps_what_was_completed_today_until_midnight() {
    let d = device();
    // The stamps of a device never go back, so the earlier day comes first.
    d.set_now_for_tests("2026-10-04T23:50");
    d.set_keep_done(KeepDone::EndOfDay).unwrap();
    add(&d, "а");
    let yesterday = add(&d, "вчера");
    let b = add(&d, "б");
    d.complete_task(yesterday.id).unwrap();
    assert_eq!(view(&d, Scope::Inbox), ["а", "вчера", "б"], "kept on its own day");

    d.set_now_for_tests("2026-10-05T10:00");
    assert_eq!(view(&d, Scope::Inbox), ["а", "б"], "that day is over");
    assert_eq!(d.seconds_until_kept_leaves().unwrap(), None);
    d.complete_task(b.id).unwrap();
    assert_eq!(d.seconds_until_kept_leaves().unwrap(), Some(14 * 3600));

    d.set_now_for_tests("2026-10-05T23:59:59");
    let tasks = d.tasks(Scope::Inbox).unwrap();
    assert_eq!(titles(&tasks), ["а", "б"]);
    assert!(tasks[1].done.is_some(), "shown as completed");
    assert_eq!(d.counts().unwrap().inbox, 1, "not counted as open");
    assert_eq!(d.seconds_until_kept_leaves().unwrap(), Some(1));

    d.set_now_for_tests("2026-10-06T00:00");
    assert_eq!(view(&d, Scope::Inbox), ["а"], "gone at midnight");
    assert_eq!(view(&d, Scope::Completed), ["б", "вчера"]);
    assert_eq!(d.seconds_until_kept_leaves().unwrap(), None);
}

#[test]
fn s32_the_time_is_stored_so_that_a_version_that_knows_only_minutes_can_read_it() {
    let d = device();
    let stored = |keep| {
        d.set_keep_done(keep).unwrap();
        d.setting_for_tests("keep_done").unwrap()
    };
    assert_eq!(stored(KeepDone::Seconds { seconds: 0 }), serde_json::json!(0));
    assert_eq!(stored(KeepDone::Seconds { seconds: 900 }), serde_json::json!(15));
    assert_eq!(stored(KeepDone::Seconds { seconds: 5 }), serde_json::json!("5s"));
    assert_eq!(stored(KeepDone::Seconds { seconds: 15 }), serde_json::json!("15s"));
    assert_eq!(stored(KeepDone::EndOfDay), serde_json::json!("day"));

    // What such a version wrote, and what a later one may write.
    let read = |value| {
        d.set_setting_for_tests("keep_done", value);
        d.keep_done().unwrap()
    };
    assert_eq!(read(serde_json::json!(15)), KeepDone::Seconds { seconds: 900 });
    assert_eq!(read(serde_json::json!(100_000)), KeepDone::Seconds { seconds: 86_400 });
    assert_eq!(read(serde_json::json!("90s")), KeepDone::Seconds { seconds: 90 });
    assert_eq!(
        read(serde_json::json!("9999999s")),
        KeepDone::Seconds { seconds: 86_400 }
    );
    for unknown in [
        serde_json::json!("week"),
        serde_json::json!("s"),
        serde_json::json!(-1),
        serde_json::json!(null),
    ] {
        assert_eq!(
            read(unknown.clone()),
            KeepDone::Seconds { seconds: 5 },
            "{unknown}: the default"
        );
    }
}

#[test]
fn r68_where_completed_tasks_are_shown_a_kept_one_joins_them_later() {
    let d = device();
    let list = d.create_list("Дом".into()).unwrap();
    d.set_list_show_done(list.id.clone(), true).unwrap();
    let in_list = |title: &str| {
        d.create_task(NewTask {
            title: title.into(),
            list_id: Some(list.id.clone()),
            ..NewTask::default()
        })
        .unwrap()
    };
    in_list("а");
    let b = in_list("б");
    in_list("в");
    let project = add(&d, "проект");
    d.set_project(project.id.clone(), true).unwrap();
    add_sub(&d, &project, "раз");
    let two = add_sub(&d, &project, "два");
    add_sub(&d, &project, "три");
    let of_list = || view(&d, Scope::List { id: list.id.clone() });
    let of_project = || view(&d, Scope::Project { id: project.id.clone() });
    let open_and_all = |status| {
        titles(
            &d.preview_filter(FilterSpec {
                list_ids: vec![list.id.clone()],
                status,
                ..FilterSpec::default()
            })
            .unwrap(),
        )
        .into_iter()
        .map(str::to_string)
        .collect::<Vec<_>>()
    };

    d.complete_task(b.id).unwrap();
    d.complete_task(two.id).unwrap();
    assert_eq!(of_list(), ["а", "б", "в"]);
    assert_eq!(of_project(), ["раз", "два", "три"]);
    assert_eq!(open_and_all(FilterStatus::Open), ["а", "б", "в"]);
    assert_eq!(open_and_all(FilterStatus::All), ["а", "б", "в"]);

    d.set_now_for_tests("2026-10-05T10:06");
    assert_eq!(of_list(), ["а", "в", "б"]);
    assert_eq!(of_project(), ["раз", "три", "два"]);
    assert_eq!(open_and_all(FilterStatus::Open), ["а", "в"]);
    assert_eq!(open_and_all(FilterStatus::All), ["а", "в", "б"]);
}

#[test]
fn r68_a_repeating_task_moves_on_and_a_far_clock_does_not_keep_a_task() {
    let d = device();
    let weekly_task = due_today(&d, "каждую неделю");
    d.set_repeat(weekly_task.id.clone(), Some(weekly())).unwrap();
    let next = d.complete_task(weekly_task.id).unwrap();
    assert!(next.done.is_none());
    assert!(
        view(&d, Scope::Today).is_empty(),
        "the record of the repeat is not a row of the view"
    );
    assert_eq!(view(&d, Scope::Upcoming), ["каждую неделю"]);

    // Completed where the clock is three hours ahead: `done` carries no time zone.
    let far = due_today(&d, "издалека");
    d.set_now_for_tests("2026-10-05T13:00");
    d.complete_task(far.id).unwrap();
    d.set_now_for_tests("2026-10-05T10:01");
    assert!(view(&d, Scope::Today).is_empty());
}

#[test]
fn r68_the_time_runs_to_the_second_and_the_store_tells_when_it_ends() {
    let d = device();
    d.set_keep_done(KeepDone::Seconds { seconds: 15 }).unwrap();
    assert_eq!(d.seconds_until_kept_leaves().unwrap(), None, "nothing is kept");
    due_today(&d, "а");
    let b = due_today(&d, "б");

    d.set_now_for_tests("2026-10-05T10:00:40");
    d.complete_task(b.id).unwrap();
    d.set_now_for_tests("2026-10-05T10:00:50");
    assert_eq!(view(&d, Scope::Today), ["а", "б"]);
    assert_eq!(d.seconds_until_kept_leaves().unwrap(), Some(6));

    d.set_now_for_tests("2026-10-05T10:00:54");
    assert_eq!(view(&d, Scope::Today), ["а", "б"], "a second before the time is over");
    d.set_now_for_tests("2026-10-05T10:00:56");
    assert_eq!(view(&d, Scope::Today), ["а"], "a second after");
    assert_eq!(d.seconds_until_kept_leaves().unwrap(), None);

    d.set_keep_done(KeepDone::Seconds { seconds: 0 }).unwrap();
    assert_eq!(
        d.seconds_until_kept_leaves().unwrap(),
        None,
        "at once: nothing to wait for"
    );
}

#[test]
fn r69_a_task_closed_as_wont_do_is_kept_then_logged_and_can_be_reopened() {
    let d = device();
    let a = add(&d, "а");
    let b = add(&d, "б");
    add(&d, "в");

    let closed = d.wont_do_task(b.id.clone()).unwrap();
    assert!(closed.wont && closed.done.is_some());
    d.set_now_for_tests("2026-10-05T10:00:04");
    let inbox = d.tasks(Scope::Inbox).unwrap();
    assert_eq!(titles(&inbox), ["а", "б", "в"], "kept where it was (R68)");
    assert!(inbox[1].wont);
    assert_eq!(d.counts().unwrap().inbox, 2, "not counted as open");

    d.complete_task(a.id.clone()).unwrap();
    d.set_now_for_tests("2026-10-05T10:30");
    assert_eq!(view(&d, Scope::Inbox), ["в"]);
    assert_eq!(view(&d, Scope::Completed), ["а", "б"], "both outcomes are in the log");
    assert_eq!(view(&d, Scope::WontDo), ["б"]);
    assert!(!d.task(a.id.clone()).unwrap().wont);

    // Closing a closed task either way changes nothing.
    assert!(d.complete_task(b.id.clone()).unwrap().wont);
    assert!(!d.wont_do_task(a.id).unwrap().wont);

    d.reopen_task(b.id.clone()).unwrap();
    let back = d.task(b.id.clone()).unwrap();
    assert!(back.done.is_none() && !back.wont);
    assert_eq!(view(&d, Scope::Inbox), ["б", "в"]);
    assert!(view(&d, Scope::WontDo).is_empty());

    // Completed after that, it is completed.
    assert!(!d.complete_task(b.id).unwrap().wont);
    assert!(view(&d, Scope::WontDo).is_empty());
}

#[test]
fn r69_open_subtasks_get_the_same_outcome_and_completed_ones_keep_theirs() {
    let d = device();
    let top = add(&d, "родитель");
    let done = add_sub(&d, &top, "сделана");
    let open = add_sub(&d, &top, "открыта");
    let deep = add_sub(&d, &open, "глубже");
    d.complete_task(done.id.clone()).unwrap();

    d.wont_do_task(top.id.clone()).unwrap();
    assert!(d.task(open.id.clone()).unwrap().wont);
    assert!(d.task(deep.id).unwrap().wont);
    let kept = d.task(done.id).unwrap();
    assert!(kept.done.is_some() && !kept.wont);
    assert_eq!(view(&d, Scope::WontDo), ["родитель"], "subtasks go with their task");

    // Reopening the parent leaves the subtasks alone (R11).
    d.reopen_task(top.id).unwrap();
    assert!(d.task(open.id).unwrap().wont);
}

#[test]
fn r69_r17_a_repeating_task_skips_the_occurrence() {
    let d = device();
    let t = add(&d, "зарядка");
    d.set_due(t.id.clone(), Some("2026-10-05".into())).unwrap();
    d.set_repeat(t.id.clone(), Some(weekly())).unwrap();
    let sub = add_sub(&d, &t, "разминка");
    d.wont_do_task(sub.id.clone()).unwrap();

    let after = d.wont_do_task(t.id.clone()).unwrap();
    assert!(after.done.is_none() && !after.wont, "the task stays open");
    assert_eq!(after.due.as_deref(), Some("2026-10-12"));
    let sub = d.task(sub.id).unwrap();
    assert!(
        sub.done.is_none() && !sub.wont,
        "subtasks are reopened for the next round"
    );

    let log = d.tasks(Scope::WontDo).unwrap();
    assert_eq!(titles(&log), ["зарядка"]);
    assert!(log[0].is_log && log[0].wont);
    assert_eq!(log[0].due.as_deref(), Some("2026-10-05"));
    assert_eq!(view(&d, Scope::Completed), ["зарядка"]);

    // The next occurrence is completed: its record is a completed one.
    d.complete_task(t.id).unwrap();
    assert_eq!(view(&d, Scope::Completed).len(), 2);
    assert_eq!(view(&d, Scope::WontDo).len(), 1);
}

#[test]
fn r69_r30_wont_do_tasks_leave_both_numbers_of_the_counter() {
    let d = device();
    let project = add(&d, "проект");
    d.set_project(project.id.clone(), true).unwrap();
    let one = add_sub(&d, &project, "раз");
    let two = add_sub(&d, &project, "два");
    let three = add_sub(&d, &project, "три");
    d.complete_task(one.id).unwrap();
    d.complete_task(two.id).unwrap();
    assert_eq!(d.projects().unwrap()[0].subtasks_total, 3);

    d.wont_do_task(three.id.clone()).unwrap();
    let p = &d.projects().unwrap()[0];
    assert_eq!((p.subtasks_done, p.subtasks_total), (2, 2));

    d.reopen_task(three.id).unwrap();
    let p = &d.projects().unwrap()[0];
    assert_eq!((p.subtasks_done, p.subtasks_total), (2, 3));
}

#[test]
fn r69_r33_a_filter_tells_the_two_outcomes_apart() {
    let d = device();
    add(&d, "открыта");
    let done = add(&d, "выполнена");
    let wont = add(&d, "не буду");
    d.complete_task(done.id).unwrap();
    d.wont_do_task(wont.id).unwrap();
    d.set_now_for_tests("2026-10-05T10:30");

    let show = |status: FilterStatus| {
        let mut got = view_of(&d.preview_filter(FilterSpec { status, ..spec() }).unwrap());
        got.sort();
        got
    };
    assert_eq!(show(FilterStatus::Open), ["открыта"]);
    assert_eq!(show(FilterStatus::Done), ["выполнена"]);
    assert_eq!(show(FilterStatus::Wont), ["не буду"]);
    assert_eq!(show(FilterStatus::All), ["выполнена", "не буду", "открыта"]);

    // The value is stored and read back under its own name.
    let saved = d
        .create_filter(
            "брошенное".into(),
            FilterSpec {
                status: FilterStatus::Wont,
                ..spec()
            },
        )
        .unwrap();
    assert_eq!(view(&d, Scope::Filter { id: saved.id }), ["не буду"]);
}

fn view_of(tasks: &[TaskItem]) -> Vec<String> {
    tasks.iter().map(|t| t.title.clone()).collect()
}

#[test]
fn r69_r46_clearing_completed_removes_both_outcomes() {
    let d = device();
    d.set_now_for_tests("2026-09-01T09:00");
    let done = add(&d, "выполнена");
    let wont = add(&d, "не буду");
    d.complete_task(done.id).unwrap();
    d.wont_do_task(wont.id).unwrap();
    d.set_now_for_tests(NOW);
    assert_eq!(view(&d, Scope::Completed).len(), 2);

    assert_eq!(d.clear_completed(Some("2026-10-01".into())).unwrap(), 2);
    assert!(view(&d, Scope::Completed).is_empty());
    assert!(view(&d, Scope::WontDo).is_empty());
}

/// Attaches a file with that name and content and returns the attachment as the views get it.
fn shown_attachment(d: &Device, name: &str, content: &[u8]) -> Attachment {
    let task = add(&d.store, name);
    let src = tempfile::tempdir().unwrap();
    let file = src.path().join(name);
    std::fs::write(&file, content).unwrap();
    d.add_attachment(task.id.clone(), file.to_string_lossy().into_owned(), None)
        .unwrap();
    d.attachments(task.id).unwrap().remove(0)
}

#[test]
fn r85_a_name_without_a_type_takes_the_type_of_the_content() {
    let d = device();
    let jpeg = shown_attachment(&d, "Image", &[0xFF, 0xD8, 0xFF, 0xE0, 0, 16, b'J', b'F', b'I', b'F']);
    assert_eq!((jpeg.name.as_str(), jpeg.mime.as_str()), ("Image.jpg", "image/jpeg"));
    let pdf = shown_attachment(&d, "Scan", b"%PDF-1.7 and the rest");
    assert_eq!((pdf.name.as_str(), pdf.mime.as_str()), ("Scan.pdf", "application/pdf"));
    let png = shown_attachment(&d, "shot", b"\x89PNG\r\n\x1a\n0000");
    assert_eq!((png.name.as_str(), png.mime.as_str()), ("shot.png", "image/png"));
}

#[test]
fn r85_a_name_that_tells_the_type_and_content_that_tells_none_are_left_alone() {
    let d = device();
    // The name decides when it can, whatever the bytes are.
    let named = shown_attachment(&d, "notes.txt", &[0xFF, 0xD8, 0xFF, 0xE0]);
    assert_eq!((named.name.as_str(), named.mime.as_str()), ("notes.txt", "text/plain"));
    // Unknown bytes under an unknown name stay what they were.
    let unknown = shown_attachment(&d, "blob", b"nothing known here");
    assert_eq!(
        (unknown.name.as_str(), unknown.mime.as_str()),
        ("blob", "application/octet-stream")
    );
    // An extension that tells nothing is kept; only the type is learnt from the content.
    let odd = shown_attachment(&d, "export.dat", b"GIF89a....");
    assert_eq!((odd.name.as_str(), odd.mime.as_str()), ("export.dat", "image/gif"));
}

#[test]
fn r85_the_registers_keep_the_name_the_file_came_with() {
    let d = device();
    let shown = shown_attachment(&d, "Image", &[0xFF, 0xD8, 0xFF, 0xE0]);
    assert_eq!(shown.name, "Image.jpg");
    // Without the content the name is what was stored: nothing was written back.
    std::fs::remove_file(shown.local_path.unwrap()).unwrap();
    let bare = d.attachments(shown.task_id).unwrap().remove(0);
    assert_eq!(
        (bare.name.as_str(), bare.mime.as_str()),
        ("Image", "application/octet-stream")
    );
}

/// The files of a folder with their content, by name.
fn folder_content(dir: &std::path::Path) -> Vec<(String, Vec<u8>)> {
    let mut all: Vec<_> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap())
        .map(|e| {
            (
                e.file_name().to_string_lossy().into_owned(),
                std::fs::read(e.path()).unwrap(),
            )
        })
        .collect();
    all.sort();
    all
}

fn attach_named(d: &Device, task: &TaskItem, name: &str, content: &[u8]) -> Attachment {
    let src = tempfile::tempdir().unwrap();
    let file = src.path().join("source");
    std::fs::write(&file, content).unwrap();
    d.add_attachment(task.id.clone(), file.to_string_lossy().into_owned(), Some(name.into()))
        .unwrap()
}

fn named(name: &str, content: &[u8]) -> (String, Vec<u8>) {
    (name.to_string(), content.to_vec())
}

#[test]
fn r91_every_attachment_is_saved_under_its_name() {
    let d = device();
    let t = add(&d, "с тремя файлами");
    attach_named(&d, &t, "a.txt", b"first");
    attach_named(&d, &t, "b.pdf", b"%PDF-1.7 second");
    attach_named(&d, &t, "c.png", b"third");
    let out = tempfile::tempdir().unwrap();

    let report = d
        .save_attachments(t.id.clone(), out.path().to_string_lossy().into_owned())
        .unwrap();

    let mut saved = report.saved.clone();
    saved.sort();
    assert_eq!(saved, ["a.txt", "b.pdf", "c.png"]);
    assert_eq!((report.failed.len(), report.fetched), (0, 0));
    assert_eq!(
        folder_content(out.path()),
        [
            named("a.txt", b"first"),
            named("b.pdf", b"%PDF-1.7 second"),
            named("c.png", b"third")
        ]
    );
    // The content behind the attachments is where it was.
    assert!(d.attachments(t.id).unwrap().iter().all(|f| f.local_path.is_some()));
}

#[test]
fn r91_a_name_that_is_taken_gets_a_number_and_nothing_is_replaced() {
    let d = device();
    let t = add(&d, "с одинаковыми именами");
    attach_named(&d, &t, "a.txt", b"one");
    attach_named(&d, &t, "a.txt", b"two");
    attach_named(&d, &t, "notes", b"three");
    attach_named(&d, &t, ".env", b"four");
    let out = tempfile::tempdir().unwrap();
    for (name, content) in [
        ("a.txt", "was here"),
        ("a 2.txt", "and this"),
        ("notes", "old"),
        (".env", "kept"),
    ] {
        std::fs::write(out.path().join(name), content).unwrap();
    }

    let dir = out.path().to_string_lossy().into_owned();
    let report = d.save_attachments(t.id.clone(), dir.clone()).unwrap();

    assert!(report.failed.is_empty(), "{report:?}");
    let all = folder_content(out.path());
    for kept in [
        named("a.txt", b"was here"),
        named("a 2.txt", b"and this"),
        named("notes", b"old"),
        named(".env", b"kept"),
    ] {
        assert!(all.contains(&kept), "{kept:?} in {all:?}");
    }
    // Two attachments share a name: both are there, each under a name of its own.
    let numbered: Vec<_> = all
        .iter()
        .filter(|(name, _)| name == "a 3.txt" || name == "a 4.txt")
        .collect();
    let mut content: Vec<_> = numbered.iter().map(|(_, c)| c.as_slice()).collect();
    content.sort();
    assert_eq!(content, [b"one".as_slice(), b"two".as_slice()]);
    assert!(all.contains(&named("notes 2", b"three")), "{all:?}");
    assert!(all.contains(&named(".env 2", b"four")), "{all:?}");
    assert_eq!(all.len(), 8);

    // A second run adds a second set and still replaces nothing.
    d.save_attachments(t.id, dir).unwrap();
    assert_eq!(folder_content(out.path()).len(), 12);
}

#[test]
fn r91_a_name_from_another_device_stays_inside_the_folder() {
    let d = device();
    let t = add(&d, "с чужим именем");
    attach_named(&d, &t, "../up/and:out.txt", b"escaped");
    attach_named(&d, &t, "plain.txt", b"plain");
    let parent = tempfile::tempdir().unwrap();
    let out = parent.path().join("chosen");
    std::fs::create_dir(&out).unwrap();

    let report = d.save_attachments(t.id, out.to_string_lossy().into_owned()).unwrap();

    assert!(report.failed.is_empty(), "{report:?}");
    assert_eq!(
        folder_content(&out),
        [named(".._up_and_out.txt", b"escaped"), named("plain.txt", b"plain")]
    );
    assert_eq!(std::fs::read_dir(parent.path()).unwrap().count(), 1);
}

#[test]
fn r91_a_file_that_cannot_be_written_is_named_and_the_rest_are_saved() {
    let d = device();
    let t = add(&d, "с потерянным файлом");
    let lost = attach_named(&d, &t, "lost.txt", b"lost");
    attach_named(&d, &t, "kept.txt", b"kept");
    // The content is gone from the device and there is no storage to take it from.
    std::fs::remove_file(lost.local_path.unwrap()).unwrap();
    let out = tempfile::tempdir().unwrap();

    let report = d
        .save_attachments(t.id.clone(), out.path().to_string_lossy().into_owned())
        .unwrap();

    assert_eq!(
        (report.saved, report.failed, report.fetched),
        (vec!["kept.txt".to_string()], vec!["lost.txt".to_string()], 0)
    );
    assert_eq!(folder_content(out.path()), [named("kept.txt", b"kept")]);

    // A folder that is not there: every file is named, nothing is thrown.
    let nowhere = out.path().join("missing").to_string_lossy().into_owned();
    let report = d.save_attachments(t.id, nowhere).unwrap();
    assert_eq!((report.saved.len(), report.failed.len()), (0, 2));
}
