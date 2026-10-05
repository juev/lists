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
    assert_eq!(of(&d), ["b"]);
    d.set_list_show_done(list.id.clone(), true).unwrap();
    assert_eq!(of(&d), ["b", "a"], "completed tasks go last");
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
