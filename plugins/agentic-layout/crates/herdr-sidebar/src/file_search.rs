use std::path::Path;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::text::Line;

use crate::tree::{Row, Tree};
use crate::ui::footer_input_line;

pub const LIMIT: usize = 200;

#[derive(Clone, Debug, Default)]
pub struct FileSearch {
    query: Option<String>,
}

pub enum SearchKey {
    Ignore,
    Changed,
    Cancel,
    Confirm,
    Move(isize),
    Page(isize),
    Home,
    End,
}

impl FileSearch {
    pub fn active(&self) -> bool {
        self.query.is_some()
    }

    pub fn start(&mut self) {
        self.query = Some(String::new());
    }

    pub fn cancel(&mut self) {
        self.query = None;
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> SearchKey {
        match key.code {
            KeyCode::Esc => {
                self.cancel();
                SearchKey::Cancel
            }
            KeyCode::Backspace => {
                if let Some(query) = &mut self.query {
                    query.pop();
                }
                SearchKey::Changed
            }
            KeyCode::Enter => SearchKey::Confirm,
            KeyCode::Up | KeyCode::Char('k') => SearchKey::Move(-1),
            KeyCode::Down | KeyCode::Char('j') => SearchKey::Move(1),
            KeyCode::PageUp => SearchKey::Page(-1),
            KeyCode::PageDown => SearchKey::Page(1),
            KeyCode::Home | KeyCode::Char('g') => SearchKey::Home,
            KeyCode::End | KeyCode::Char('G') => SearchKey::End,
            KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                if let Some(query) = &mut self.query {
                    query.push(c);
                }
                SearchKey::Changed
            }
            _ => SearchKey::Ignore,
        }
    }

    pub fn apply(&self, tree: &mut Tree) -> (Vec<Row>, Option<usize>) {
        let query = self.query.as_deref().unwrap_or("").trim();
        if query.is_empty() {
            return (Vec::new(), None);
        }
        let rows = tree.search(query, LIMIT);
        let selected = if rows.is_empty() { None } else { Some(0) };
        (rows, selected)
    }

    pub fn empty_message(&self) -> &'static str {
        if self.query.as_deref().is_some_and(|q| q.trim().is_empty()) {
            "  / type a file name…"
        } else {
            "  (no matches)"
        }
    }

    pub fn footer_line(&self, width: u16) -> Vec<Line<'static>> {
        footer_input_line(
            "/",
            self.query.as_deref().unwrap_or(""),
            "  (⏎ open · esc cancel)",
            width,
        )
    }

    pub fn reveal_in_tree(tree: &mut Tree, path: &Path) -> Option<usize> {
        let root = tree.root_path();
        if !path.starts_with(&root) {
            return None;
        }
        let mut cur = path.parent();
        while let Some(dir) = cur {
            if dir.starts_with(&root) {
                tree.expand(dir);
            }
            if dir == root {
                break;
            }
            cur = dir.parent();
        }
        if path.is_dir() {
            tree.expand(path);
        }
        let rows = tree.rows();
        rows.iter().position(|r| r.path == path)
    }
}
