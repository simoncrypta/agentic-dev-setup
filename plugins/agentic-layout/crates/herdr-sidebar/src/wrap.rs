//! Width-aware wrapping of styled lines for the preview/diff pane.
//!
//! ratatui's `Paragraph::wrap` could wrap for us, but only AFTER the viewer
//! has sliced out the visible lines — its continuation rows then spill past
//! the bottom of the pane, and a scroll that counts SOURCE lines can never
//! bring them back. Wrapping here instead turns one source line into N
//! rendered rows that the viewer scrolls through like any other row, so
//! every continuation is reachable (see `viewer::build_rows`).

use ratatui::style::Style;
use ratatui::text::{Line, Span};
use unicode_width::UnicodeWidthChar;

const TAB_WIDTH: usize = 4;

/// Split `line` into rows at most `width` columns wide, preserving each
/// span's style and the line's own style (the diff row tint).
///
/// Greedy word wrap: a break prefers the last space that fits, and a word
/// longer than `width` is hard-broken so no content is ever dropped.
/// Leading indentation is never trimmed, so wrapped code stays readable.
/// A `width` of 0 is meaningless — the line comes back whole.
pub fn wrap_line(line: &Line<'static>, width: usize) -> Vec<Line<'static>> {
    if width == 0 {
        return vec![line.clone()];
    }
    // One flat run of (char, display width, style): a break may fall
    // anywhere, including mid-span, so per-span wrapping won't do.
    let cells: Vec<(char, Style)> = line
        .spans
        .iter()
        .flat_map(|span| {
            let style = span.style;
            span.content.chars().map(move |c| (c, style))
        })
        .collect();
    if cells.is_empty() {
        return vec![line.clone()];
    }

    let mut rows: Vec<Line<'static>> = Vec::new();
    let mut start = 0usize;
    while start < cells.len() {
        let mut end = start;
        let mut used = 0usize;
        // Index just past the last space that fits — a clean break point.
        let mut last_space: Option<usize> = None;
        while end < cells.len() {
            let (c, _) = cells[end];
            let w = char_width(c, used);
            // `end > start` keeps a single too-wide char from stalling.
            if used + w > width && end > start {
                break;
            }
            used += w;
            end += 1;
            if c == ' ' {
                last_space = Some(end);
            }
        }
        // Back up to the last space rather than cutting a word in half —
        // unless the row already ends on a boundary, or the word alone is
        // wider than the pane (then the hard break stands).
        let cut = match last_space {
            Some(b) if end < cells.len() && cells[end].0 != ' ' && b > start => b,
            _ => end,
        };
        rows.push(row_from(&cells[start..cut], line.style));
        start = cut;
    }
    rows
}

/// Re-fuse adjacent cells that share a style back into spans.
fn row_from(cells: &[(char, Style)], line_style: Style) -> Line<'static> {
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut x = 0usize;
    for (c, style) in cells {
        let text = if *c == '\t' {
            " ".repeat(char_width(*c, x))
        } else {
            c.to_string()
        };
        match spans.last_mut() {
            Some(last) if last.style == *style => last.content.to_mut().push_str(&text),
            _ => spans.push(Span::styled(text, *style)),
        }
        x += char_width(*c, x);
    }
    let mut row = Line::from(spans);
    row.style = line_style;
    row
}

fn char_width(c: char, x: usize) -> usize {
    if c == '\t' {
        TAB_WIDTH - (x % TAB_WIDTH)
    } else {
        c.width().unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::style::{Color, Stylize};

    fn texts(rows: &[Line<'static>]) -> Vec<String> {
        rows.iter()
            .map(|r| r.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect()
    }

    #[test]
    fn short_lines_pass_through_untouched() {
        let line = Line::raw("fits");
        assert_eq!(texts(&wrap_line(&line, 10)), vec!["fits"]);
    }

    #[test]
    fn breaks_at_spaces_and_keeps_every_character() {
        let line = Line::raw("the quick brown fox jumps");
        let rows = wrap_line(&line, 10);
        assert_eq!(texts(&rows), vec!["the quick ", "brown fox ", "jumps"]);
        // Nothing dropped, nothing duplicated.
        assert_eq!(texts(&rows).concat(), "the quick brown fox jumps");
        assert!(rows.iter().all(|r| r.width() <= 10));
    }

    #[test]
    fn a_word_wider_than_the_pane_is_hard_broken() {
        let line = Line::raw("supercalifragilistic");
        let rows = wrap_line(&line, 7);
        assert_eq!(texts(&rows), vec!["superca", "lifragi", "listic"]);
        assert_eq!(texts(&rows).concat(), "supercalifragilistic");
    }

    #[test]
    fn indentation_is_preserved_not_trimmed() {
        let line = Line::raw("        let value = compute();");
        let rows = wrap_line(&line, 16);
        assert!(
            rows[0].spans[0].content.starts_with("        "),
            "{:?}",
            texts(&rows)
        );
        assert_eq!(texts(&rows).concat(), "        let value = compute();");
    }

    #[test]
    fn span_styles_survive_the_break() {
        let line = Line::from(vec![
            Span::styled("aaaa ", Style::default().fg(Color::Red)),
            Span::styled("bbbb cccc", Style::default().fg(Color::Green)),
        ]);
        let rows = wrap_line(&line, 6);
        assert_eq!(texts(&rows).concat(), "aaaa bbbb cccc");
        // The red run never bleeds onto the green text.
        for row in &rows {
            for span in &row.spans {
                let expected = if span.content.contains('a') {
                    Color::Red
                } else {
                    Color::Green
                };
                assert_eq!(span.style.fg, Some(expected), "{:?}", span.content);
            }
        }
    }

    #[test]
    fn the_line_style_rides_along_so_diff_tints_cover_continuations() {
        let line = Line::raw("added a very long line of code").on_red();
        let rows = wrap_line(&line, 12);
        assert!(rows.len() > 1);
        assert!(rows.iter().all(|r| r.style.bg == Some(Color::Red)));
    }

    #[test]
    fn wide_glyphs_count_two_columns() {
        let line = Line::raw("日本語テキスト");
        let rows = wrap_line(&line, 6);
        assert!(rows.iter().all(|r| r.width() <= 6), "{:?}", texts(&rows));
        assert_eq!(texts(&rows).concat(), "日本語テキスト");
    }

    #[test]
    fn tabs_advance_to_the_next_stop_and_render_as_spaces() {
        let rows = wrap_line(&Line::raw("\t1234"), 4);
        assert_eq!(texts(&rows), vec!["    ", "1234"]);
        assert!(rows.iter().all(|row| row.width() <= 4));
    }

    #[test]
    fn degenerate_widths_terminate() {
        let line = Line::raw("abc");
        assert_eq!(texts(&wrap_line(&line, 0)), vec!["abc"]);
        assert_eq!(texts(&wrap_line(&line, 1)), vec!["a", "b", "c"]);
        assert_eq!(texts(&wrap_line(&Line::raw(""), 4)), vec![""]);
    }
}
