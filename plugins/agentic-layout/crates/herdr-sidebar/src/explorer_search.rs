use crossterm::event::KeyEvent;

use herdr_sidebar::file_search::{FileSearch, SearchKey};
use herdr_sidebar::state::Exit;

use super::App;

pub(super) fn on_search_key(app: &mut App, key: KeyEvent) -> Option<Exit> {
    match app.search.handle_key(key) {
        SearchKey::Cancel => app.rebuild(),
        SearchKey::Changed => apply_search(app),
        SearchKey::Confirm => activate_search_selection(app),
        SearchKey::Move(delta) => app.move_by(delta),
        SearchKey::Page(delta) => app.move_by(delta * app.page as isize),
        SearchKey::Home => app.select(0),
        SearchKey::End => app.select(app.rows.len().saturating_sub(1)),
        SearchKey::Ignore => {}
    }
    None
}

pub(super) fn apply_search(app: &mut App) {
    app.hovered = None;
    let (rows, selected) = app.search.apply(&mut app.tree);
    app.rows = rows;
    app.selected = selected;
    app.scroll = 0;
    app.snap = selected.is_some();
}

fn activate_search_selection(app: &mut App) {
    let Some(row) = app.selected_row() else {
        return;
    };
    let path = row.path.clone();
    let is_file = !row.is_dir;
    app.search.cancel();
    if let Some(index) = FileSearch::reveal_in_tree(&mut app.tree, &path) {
        app.rows = app.tree.rows();
        app.select(index);
        app.snap = true;
    } else {
        app.rebuild();
    }
    if is_file {
        app.open_preview(&path);
    }
}
