#![allow(dead_code)]

use std::sync::Arc;

use lists_core::{NewTask, Scope, Store, TaskItem};
use tempfile::TempDir;

/// 2026-10-05 is a Monday.
pub const NOW: &str = "2026-10-05T10:00";

pub struct Device {
    pub store: Arc<Store>,
    _dir: TempDir,
}

impl std::ops::Deref for Device {
    type Target = Store;
    fn deref(&self) -> &Store {
        &self.store
    }
}

pub fn device() -> Device {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::open(dir.path().to_string_lossy().into_owned()).unwrap();
    store.set_now_for_tests(NOW);
    Device { store, _dir: dir }
}

pub fn add(store: &Store, title: &str) -> TaskItem {
    store
        .create_task(NewTask {
            title: title.into(),
            ..NewTask::default()
        })
        .unwrap()
}

pub fn add_sub(store: &Store, parent: &TaskItem, title: &str) -> TaskItem {
    store
        .create_task(NewTask {
            title: title.into(),
            parent_id: Some(parent.id.clone()),
            ..NewTask::default()
        })
        .unwrap()
}

pub fn titles(tasks: &[TaskItem]) -> Vec<&str> {
    tasks.iter().map(|t| t.title.as_str()).collect()
}

pub fn view(store: &Store, view: Scope) -> Vec<String> {
    store.tasks(view).unwrap().into_iter().map(|t| t.title).collect()
}
