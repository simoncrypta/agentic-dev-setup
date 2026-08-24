//! Shared library behind the sidebar binaries: the sidebar TUI
//! (`herdr-sidebar`, hosting BOTH views — file explorer and source
//! control — plus the `--preview` file viewer) and the windowless ensure
//! sidecar (`herdr-sidebar-ensure`).

pub mod actions;
pub mod ansi;
pub mod diffview;
pub mod editor;
pub mod embed;
pub mod ensure;
pub mod file_search;
pub mod fontsetup;
pub mod git;
pub mod gitdeco;
pub mod herdr_json;
pub mod icons;
pub mod ipc;
pub mod launch;
pub mod layout_plan;
pub mod sidebar_root;
pub mod snooze;
pub mod state;
pub mod suggest;
pub mod syntax;
pub mod tree;
pub mod ui;
pub mod viewer;
pub mod wrap;
