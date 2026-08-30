use ratatui::style::{Color, Stylize};
use ratatui::text::Line;

use herdr_sidebar::ui::{footer_input_line, wrap_footer_message, wrap_hints};

use super::{App, Overlay};

pub(super) fn essential_hints(app: &App) -> Vec<(&'static str, &'static str)> {
    let mut hints = vec![
        ("/", "search"),
        ("⏎", "toggle"),
        ("m", "menu"),
        ("s", "settings"),
    ];
    if app.ctx.uses_external_editor() {
        hints.push(("v", "review"));
    }
    if app.merged() {
        hints.extend([("1", "files"), ("2", "git")]);
    }
    hints
}

pub(super) fn hints(app: &App) -> Vec<(&'static str, &'static str)> {
    let mut hints = vec![
        ("/", "fuzzy search"),
        ("↑↓", "move"),
        ("←→", "fold"),
        ("⏎", "toggle"),
        ("r", "refresh"),
        (".", "dotfiles"),
        ("c", "folder"),
        ("m", "menu"),
        ("s", "settings"),
        ("q", "quit"),
    ];
    if app.ctx.uses_external_editor() {
        hints.push(("v", "review"));
    }
    if app.merged() {
        hints.extend([("1", "files"), ("2", "git")]);
    }
    hints
}

pub(super) fn footer_message(app: &App) -> Option<(String, Color)> {
    if let Some(notice) = &app.notice {
        return Some((notice.clone(), Color::Yellow));
    }
    if let Some(Overlay::ConfirmDelete { path, .. }) = &app.overlay {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        return Some((format!("Delete '{name}' permanently? (y/N)"), Color::Red));
    }
    None
}

pub(super) fn footer_lines(app: &App, width: u16) -> Vec<Line<'static>> {
    if app.search.active() {
        return app.search.footer_line(width);
    }
    if let Some(Overlay::Prompt { title, input, .. }) = &app.overlay {
        return footer_input_line(
            &format!(" {title}: "),
            input,
            "  (⏎ ok · esc cancel)",
            width,
        );
    }

    let mut lines = Vec::new();
    if let Some((msg, color)) = footer_message(app) {
        lines.extend(
            wrap_footer_message(&msg, width, 4)
                .into_iter()
                .map(|l| l.fg(color).into()),
        );
    }

    let hint_list = if app.show_hotkeys() {
        hints(app)
    } else {
        essential_hints(app)
    };
    if !hint_list.is_empty() {
        lines.extend(wrap_hints(&hint_list, width, 0));
    }
    if lines.is_empty() {
        lines.push(Line::default());
    }
    lines
}

pub(super) fn footer_height(app: &App, width: u16) -> u16 {
    footer_lines(app, width).len().max(1) as u16
}
