//! Shared core of Lists: storage, merge of concurrent edits, sync, recurrence
//! and quick-entry parsing. The apps reach it through the UniFFI bindings
//! generated from this crate.

uniffi::setup_scaffolding!();

mod caldav;
mod db;
mod error;
mod hlc;
mod import;
mod markdown;
mod model;
mod order;
mod push;
mod quickadd;
mod recur;
mod store;
pub mod sync;

pub use error::{AppError, Result};
pub use import::ImportReport;
pub use markdown::{
    markdown_layout, markdown_newline, MarkdownAlign, MarkdownBlock, MarkdownCell, MarkdownEdit, MarkdownKind,
    MarkdownLayout, MarkdownSpan, MarkdownTable, MarkdownTableRow,
};
pub use model::*;
pub use store::{days_between, shift_date, Store};
