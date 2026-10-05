use serde::{Deserialize, Serialize};

pub const INBOX_ID: &str = "inbox";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum Priority {
    #[default]
    None,
    Low,
    Medium,
    High,
}

impl Priority {
    pub fn from_i64(v: i64) -> Self {
        match v {
            1 => Priority::Low,
            2 => Priority::Medium,
            3 => Priority::High,
            _ => Priority::None,
        }
    }
    pub fn as_i64(self) -> i64 {
        match self {
            Priority::None => 0,
            Priority::Low => 1,
            Priority::Medium => 2,
            Priority::High => 3,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, uniffi::Enum)]
pub enum SortMode {
    #[default]
    Manual,
    Due,
    Priority,
    Title,
}

impl SortMode {
    pub fn parse(s: &str) -> Self {
        match s {
            "due" => SortMode::Due,
            "priority" => SortMode::Priority,
            "title" => SortMode::Title,
            _ => SortMode::Manual,
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            SortMode::Manual => "manual",
            SortMode::Due => "due",
            SortMode::Priority => "priority",
            SortMode::Title => "title",
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TaskList {
    pub id: String,
    pub name: String,
    /// `#RRGGBB`, empty for the platform default.
    pub color: String,
    /// Platform-neutral icon name, empty for the default.
    pub icon: String,
    pub sort: SortMode,
    pub show_done: bool,
    pub default_priority: Priority,
    /// New tasks in this list are due today.
    pub default_due_today: bool,
    pub archived: bool,
    pub open_count: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum Freq {
    Daily,
    Weekly,
    Monthly,
    Yearly,
}

/// Recurrence rule. Weekdays are 1 (Monday) to 7 (Sunday).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct Repeat {
    pub freq: Freq,
    pub interval: u32,
    /// Weekly only: days of the week the task falls on. Empty means "same weekday".
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub weekdays: Vec<u32>,
    /// Monthly only: day of month, 31 meaning "last day" in shorter months.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub monthday: Option<u32>,
    /// Monthly only: 1..5 for the n-th `nth_weekday`, -1 for the last one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nth: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nth_weekday: Option<u32>,
    /// Count the next occurrence from the completion date instead of the due date.
    #[serde(default)]
    pub from_done: bool,
    /// Occurrences left, including the current one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub count: Option<u32>,
    /// Last allowed date, `YYYY-MM-DD`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub until: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TaskItem {
    pub id: String,
    /// The list the task is shown in: the list of its topmost ancestor.
    pub list_id: String,
    pub parent_id: Option<String>,
    pub parent_title: Option<String>,
    pub title: String,
    pub notes: String,
    pub start: Option<String>,
    pub due: Option<String>,
    pub priority: Priority,
    pub tags: Vec<String>,
    pub repeat: Option<Repeat>,
    pub remind: Option<String>,
    /// Completion moment, `YYYY-MM-DDTHH:MM`.
    pub done: Option<String>,
    pub deleted: bool,
    /// A record of one completed occurrence of a repeating task.
    pub is_log: bool,
    /// Shown in the sidebar and opened as a view of its own; its subtasks are the project's tasks.
    pub is_project: bool,
    pub subtasks_total: u32,
    pub subtasks_done: u32,
    pub attachments: u32,
}

#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct NewTask {
    pub title: String,
    #[uniffi(default = None)]
    pub list_id: Option<String>,
    #[uniffi(default = None)]
    pub parent_id: Option<String>,
    #[uniffi(default = "")]
    pub notes: String,
    #[uniffi(default = None)]
    pub start: Option<String>,
    #[uniffi(default = None)]
    pub due: Option<String>,
    #[uniffi(default = None)]
    pub priority: Option<Priority>,
    #[uniffi(default = [])]
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum Scope {
    Inbox,
    Today,
    Upcoming,
    All,
    Completed,
    Trash,
    List {
        id: String,
    },
    Tag {
        name: String,
    },
    Search {
        text: String,
    },
    /// The tasks of a project, completed ones last.
    Project {
        id: String,
    },
    /// A saved filter.
    Filter {
        id: String,
    },
}

/// Which dates a filter lets through. The date of a task is its due date, or
/// its start date when it has no due date.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase", tag = "kind")]
pub enum DueWindow {
    #[default]
    Any,
    Overdue,
    Today,
    /// Today and the following days, `days` in total, plus anything overdue.
    Next {
        days: u32,
    },
    NoDate,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum FilterStatus {
    #[default]
    Open,
    Done,
    All,
}

/// What a saved filter selects. Every condition that is set must hold.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Record)]
pub struct FilterSpec {
    #[serde(default)]
    pub due: DueWindow,
    /// Empty means any list.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub list_ids: Vec<String>,
    /// The task must carry all of these.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    #[serde(default)]
    pub min_priority: Priority,
    #[serde(default)]
    pub status: FilterStatus,
    /// Words the title or the note must contain; empty means no condition.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SavedFilter {
    pub id: String,
    pub name: String,
    pub spec: FilterSpec,
    pub open_count: u32,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TagCount {
    pub name: String,
    pub open_count: u32,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Counts {
    pub inbox: u32,
    pub today: u32,
    pub overdue: u32,
    pub upcoming: u32,
    pub trash: u32,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Attachment {
    pub id: String,
    pub task_id: String,
    pub name: String,
    pub mime: String,
    pub size: u64,
    pub sha256: String,
    /// Absolute path of the content if it is present on this device.
    pub local_path: Option<String>,
}

/// Result of parsing a quick-entry line.
#[derive(Debug, Clone, PartialEq, Default, uniffi::Record)]
pub struct QuickParse {
    pub title: String,
    pub due: Option<String>,
    pub priority: Priority,
    pub tags: Vec<String>,
    pub list_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum SyncConfig {
    Off,
    Folder {
        path: String,
    },
    /// The password is not part of the configuration: it is never written to
    /// the database. The app keeps it in the system keychain or keystore and
    /// hands it over with `Store::set_sync_password` after opening the store.
    WebDav {
        url: String,
        user: String,
    },
    /// A CalDAV server: lists are calendars, tasks are VTODO objects that
    /// other clients can see. The address is the calendar home or any address
    /// from which the server can name it. The password is handled as for WebDAV.
    CalDav {
        url: String,
        user: String,
    },
}

#[derive(Debug, Clone, PartialEq, Default, uniffi::Record)]
pub struct SyncReport {
    /// Field changes received that actually changed local state.
    pub pulled: u32,
    /// Field changes uploaded.
    pub pushed: u32,
    pub blobs_uploaded: u32,
    pub blobs_downloaded: u32,
}

#[derive(Debug, Clone, PartialEq, Default, uniffi::Record)]
pub struct SyncStatus {
    pub configured: bool,
    /// Local changes not uploaded yet.
    pub pending: u32,
    /// `YYYY-MM-DDTHH:MM` of the last successful run.
    pub last_ok: Option<String>,
    pub last_error: Option<String>,
}
