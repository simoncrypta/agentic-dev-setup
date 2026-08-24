//! Preview/editor tabs for file contents, git diffs, and history. One
//! ephemeral tab is reused until a double-click pins it; every preview tab
//! gets its own docked sidebar. A small control file steers each running
//! viewer so repeated clicks update in place without shell-specific launch
//! quoting. Diff requests re-run git every couple of seconds.
//! `q`/Esc (or clicking the ✕ header) closes the pane itself.
//!
//! The tail of this module is the CLIENT side — the request format plus the
//! ensure-a-viewer-pane logic both sidebar views share.

use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, KeyModifiers,
    MouseButton, MouseEvent, MouseEventKind,
};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Style, Stylize};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use unicode_width::UnicodeWidthChar;

use crate::ansi;
use crate::editor::{EditAction, Editor, SaveOutcome};
use crate::icons::{IconTheme, icon};
use crate::ipc;

/// Metadata source/token that marks the viewer pane, so the sidebar can find
/// and reuse it (distinct from the sidebar's own identity tokens).
pub const METADATA_SOURCE: &str = "herdr-sidebar-preview";

/// How often the control file is re-checked while idle.
const POLL: Duration = Duration::from_millis(250);

/// Preview size guards: don't slurp huge files into a pane.
const MAX_BYTES: usize = 1024 * 1024;
const MAX_LINES: usize = 5000;

/// Directory for the sidebar's private scratch files (viewer control files).
/// `std::env::temp_dir()` can be a shared, world-writable directory (unix
/// `/tmp`) where our filenames are predictable from the pane id; scope our
/// files into a private, mode-0700 subdirectory so another local user can't
/// plant a symlink at a path we're about to `fs::write` through. Windows'
/// per-user `%TEMP%` needs no extra scoping.
fn scratch_dir() -> PathBuf {
    let dir = std::env::temp_dir().join("herdr-sidebar-scratch");
    let _ = std::fs::create_dir_all(&dir);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
    }
    dir
}

/// Write `contents` to `path`, refusing to follow a pre-existing symlink at
/// that location (defense in depth alongside `scratch_dir`'s 0700 perms).
fn write_scratch_file(path: &Path, contents: &str) -> std::io::Result<()> {
    if std::fs::symlink_metadata(path)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
    {
        std::fs::remove_file(path)?;
    }
    std::fs::write(path, contents)
}

/// Legacy/fallback control path for previews created before control paths
/// were carried in pane metadata.
pub fn control_path_for_pane(preview_pane_id: &str) -> PathBuf {
    scratch_dir().join(format!(
        "herdr-sidebar-preview-{}.ctl",
        preview_pane_id.replace(':', "_")
    ))
}

fn fresh_control_path() -> PathBuf {
    static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let sequence = SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    scratch_dir().join(format!(
        "p-{}-{stamp:x}-{sequence:x}.ctl",
        std::process::id()
    ))
}

fn control_token(control: &Path) -> String {
    control
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| control.display().to_string())
}

fn control_from_token(token: &str) -> PathBuf {
    let path = Path::new(token);
    if path.components().count() == 1 {
        scratch_dir().join(path)
    } else {
        path.to_path_buf()
    }
}

fn document_token(doc_key: &str) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in doc_key.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

/// Identity of the document a preview shows, stamped into the preview
/// pane's `hs-preview-path` token. A file, a diff OF that file, and a
/// `git show` touching it are three different documents with three tabs.
pub fn doc_key_for_file(path: &Path) -> String {
    path.display().to_string()
}

pub fn doc_key_for_diff(root: &Path, rel: &str, kind: &str) -> String {
    format!("diff:{}:{kind}", root.join(rel).display())
}

pub fn doc_key_for_show(root: &Path, spec: &str, path: Option<&str>) -> String {
    match path {
        Some(p) => format!("show:{}:{spec}:{p}", root.display()),
        None => format!("show:{}:{spec}", root.display()),
    }
}

/// The tab name for a document. A textual `· preview` suffix marks the tab as
/// ephemeral without borrowing `*`, which users reasonably read as an unsaved
/// edit marker. A pinned tab reads as a plain name. `tab.rename` is the only
/// display lever herdr gives a plugin.
pub fn tab_label(doc_key: &str, pinned: bool) -> String {
    let display_key = if let Some(diff) = doc_key.strip_prefix("diff:") {
        diff.rsplit_once(':').map(|(path, _)| path).unwrap_or(diff)
    } else if let Some(show) = doc_key.strip_prefix("show:") {
        show.rsplit(':').next().unwrap_or(show)
    } else {
        doc_key
    };
    let name = display_key
        .rsplit(['/', '\\'])
        .next()
        .filter(|s| !s.is_empty())
        .unwrap_or(doc_key);
    if pinned {
        name.to_string()
    } else {
        format!("{name} · preview")
    }
}

/// Inverse of [`tab_label`]: the displayed name and whether it is pinned.
pub fn parse_tab_label(label: &str) -> (String, bool) {
    match label.strip_suffix(" · preview") {
        Some(rest) => (rest.to_string(), false),
        None => (label.to_string(), true),
    }
}

impl Request {
    /// The document identity this request renders.
    fn doc_key(&self) -> String {
        match self {
            Self::Close => String::new(),
            Self::File(p) => doc_key_for_file(p),
            Self::Diff { root, rel, kind } => doc_key_for_diff(root, rel, kind),
            Self::Show { root, spec, path } => doc_key_for_show(root, spec, path.as_deref()),
        }
    }
}

/// What the sidebar asked the viewer to show.
#[derive(Clone, PartialEq, Eq, Debug)]
enum Request {
    /// Graceful close request from the sidebar. The viewer gets a chance to
    /// confirm unsaved edits before it closes its own pane.
    Close,
    File(PathBuf),
    Diff {
        root: PathBuf,
        rel: String,
        /// "staged" | "worktree" | "untracked" — which diff to run.
        kind: String,
    },
    /// `git show <spec>` — a commit, stash, tag, or branch tip, optionally
    /// narrowed to one file.
    Show {
        root: PathBuf,
        spec: String,
        path: Option<String>,
    },
}

/// Control-file payload for a file preview.
pub fn file_request(path: &Path) -> String {
    format!("file\t{}", path.display())
}

/// Control-file payload for a git diff (`kind`: staged | worktree | untracked).
pub fn diff_request(root: &Path, rel: &str, kind: &str) -> String {
    format!("diff\t{}\t{rel}\t{kind}", root.display())
}

/// Control-file payload for `git show <spec>` (commit hash, stash@{n}, tag…),
/// optionally narrowed to one file.
pub fn show_request(root: &Path, spec: &str, path: Option<&str>) -> String {
    format!("show\t{}\t{spec}\t{}", root.display(), path.unwrap_or(""))
}

fn parse_request(raw: &str) -> Option<Request> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    let mut parts = raw.split('\t');
    match parts.next() {
        Some("close") => Some(Request::Close),
        Some("diff") => {
            let root = PathBuf::from(parts.next()?);
            let rel = parts.next()?.to_string();
            let kind = parts.next().unwrap_or("worktree").to_string();
            Some(Request::Diff { root, rel, kind })
        }
        Some("show") => {
            let root = PathBuf::from(parts.next()?);
            let spec = parts.next()?.to_string();
            let path = parts.next().filter(|p| !p.is_empty()).map(str::to_string);
            Some(Request::Show { root, spec, path })
        }
        Some("file") => Some(Request::File(PathBuf::from(parts.next()?))),
        // Legacy: a bare path.
        _ => Some(Request::File(PathBuf::from(raw))),
    }
}

fn request_payload(request: &Request) -> String {
    match request {
        Request::Close => "close".into(),
        Request::File(path) => file_request(path),
        Request::Diff { root, rel, kind } => diff_request(root, rel, kind),
        Request::Show { root, spec, path } => show_request(root, spec, path.as_deref()),
    }
}

struct Doc {
    name: String,
    context: String,
    lines: Vec<Line<'static>>,
    /// File previews get a line-number gutter; diffs carry their own +/-.
    numbered: bool,
    /// Offset into [`Doc::rows`] — RENDERED rows, not source lines, so a
    /// wrapped line's continuations are scrolled to like anything else.
    scroll: usize,
    /// Long lines wrap unless the user toggles them off (`w`). Per document:
    /// a newly loaded one starts wrapped again.
    wrap: bool,
    /// `lines` laid out for the pane, rebuilt only when the width or the
    /// wrap toggle changes (see [`Doc::relayout`]).
    rows: Vec<Row>,
    /// The (width, wrap) `rows` was built for; `None` until first draw.
    rows_key: Option<(u16, bool)>,
    /// Source line to scroll back to once `rows` is rebuilt — how a wrap
    /// toggle and a diff refresh keep the reader's place even though the
    /// row index underneath them changed.
    pending_src: Option<usize>,
    selection: PreviewSelection,
}

/// One rendered row of the body: the source line it came from (so scroll
/// position survives a relayout) and the styled row itself.
struct Row {
    src: usize,
    line: Line<'static>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
struct RenderPos {
    row: usize,
    col: usize,
}

#[derive(Clone, Copy, Debug, Default)]
struct PreviewSelection {
    anchor: Option<RenderPos>,
    cursor: Option<RenderPos>,
    mouse_anchor: Option<RenderPos>,
}

impl Doc {
    /// Rebuild [`Doc::rows`] for `width` when the layout inputs changed,
    /// then honour any pending source-line scroll request.
    fn relayout(&mut self, width: u16) {
        if self.rows_key != Some((width, self.wrap)) {
            self.rows = build_rows(&self.lines, self.numbered, self.wrap, width);
            self.rows_key = Some((width, self.wrap));
            self.selection = PreviewSelection::default();
        }
        if let Some(src) = self.pending_src.take() {
            self.scroll = self
                .rows
                .iter()
                .position(|r| r.src >= src)
                .unwrap_or(self.rows.len().saturating_sub(1));
        }
    }

    /// The source line at the top of the body — the anchor a relayout
    /// scrolls back to.
    fn top_src(&self) -> usize {
        self.rows.get(self.scroll).map_or(0, |r| r.src)
    }

    fn gutter(&self) -> usize {
        if self.numbered {
            self.lines.len().to_string().len() + 1
        } else {
            0
        }
    }

    fn on_mouse(&mut self, mouse: &MouseEvent, body: Rect) {
        match mouse.kind {
            MouseEventKind::Down(MouseButton::Left) => {
                let Some(position) = self.text_position_at(body, mouse.column, mouse.row) else {
                    return;
                };
                let extending = mouse.modifiers.contains(KeyModifiers::SHIFT);
                let anchor = if extending {
                    self.selection.anchor.unwrap_or(position)
                } else {
                    position
                };
                self.selection.anchor = Some(anchor);
                self.selection.cursor = Some(position);
                self.selection.mouse_anchor = Some(anchor);
            }
            MouseEventKind::Drag(MouseButton::Left) => {
                let Some(anchor) = self.selection.mouse_anchor else {
                    return;
                };
                let Some(position) = self.text_position_at(body, mouse.column, mouse.row) else {
                    return;
                };
                self.selection.anchor = Some(anchor);
                self.selection.cursor = Some(position);
            }
            MouseEventKind::Up(MouseButton::Left) => {
                if let Some(position) = self.text_position_at(body, mouse.column, mouse.row) {
                    self.selection.cursor = Some(position);
                }
                self.selection.mouse_anchor = None;
            }
            _ => {}
        }
    }

    fn text_position_at(&self, body: Rect, column: u16, row: u16) -> Option<RenderPos> {
        if column < body.x || column >= body.right() || row < body.y || row >= body.bottom() {
            return None;
        }
        let row = self.scroll + usize::from(row - body.y);
        let rendered = self.rows.get(row)?;
        let text = row_text_without_gutter(rendered, self.gutter());
        let x = usize::from(column - body.x).saturating_sub(self.gutter());
        Some(RenderPos {
            row,
            col: col_at_display_x(&text, x),
        })
    }

    fn selection_range(&self) -> Option<(RenderPos, RenderPos)> {
        let anchor = self.selection.anchor?;
        let cursor = self.selection.cursor?;
        (anchor != cursor).then(|| {
            if anchor < cursor {
                (anchor, cursor)
            } else {
                (cursor, anchor)
            }
        })
    }

    fn select_all(&mut self) {
        let Some(last) = self.rows.last() else { return };
        let last_col = row_text_without_gutter(last, self.gutter()).chars().count();
        self.selection.anchor = Some(RenderPos::default());
        self.selection.cursor = Some(RenderPos {
            row: self.rows.len() - 1,
            col: last_col,
        });
        self.selection.mouse_anchor = None;
    }

    fn selected_text(&self) -> Option<String> {
        let (start, end) = self.selection_range()?;
        let mut selected = String::new();
        for row_index in start.row..=end.row {
            let row = self.rows.get(row_index)?;
            let text = row_text_without_gutter(row, self.gutter());
            let from = if row_index == start.row { start.col } else { 0 };
            let to = if row_index == end.row {
                end.col
            } else {
                text.chars().count()
            };
            selected.push_str(&char_slice(&text, from, to));
            if row_index < end.row
                && self
                    .rows
                    .get(row_index + 1)
                    .is_some_and(|next| next.src != row.src)
            {
                selected.push('\n');
            }
        }
        Some(selected)
    }
}

fn row_text_without_gutter(row: &Row, gutter: usize) -> String {
    row.line
        .spans
        .iter()
        .flat_map(|span| span.content.chars())
        .skip(gutter)
        .collect()
}

fn col_at_display_x(text: &str, wanted: usize) -> usize {
    let mut x = 0;
    for (col, ch) in text.chars().enumerate() {
        let width = UnicodeWidthChar::width(ch).unwrap_or(0);
        if x + width > wanted {
            return col;
        }
        x += width;
    }
    text.chars().count()
}

fn char_slice(text: &str, start: usize, end: usize) -> String {
    text.chars()
        .skip(start)
        .take(end.saturating_sub(start))
        .collect()
}

fn selected_row(
    line: &Line<'static>,
    gutter: usize,
    row: usize,
    range: Option<(RenderPos, RenderPos)>,
) -> Line<'static> {
    let Some((start, end)) = range else {
        return line.clone();
    };
    if row < start.row || row > end.row {
        return line.clone();
    }
    let mut rendered = Line {
        style: line.style,
        ..Line::default()
    };
    let mut global_col: usize = 0;
    for span in &line.spans {
        for ch in span.content.chars() {
            let content_col = global_col.checked_sub(gutter);
            let selected = content_col.is_some_and(|col| {
                let after_start = row > start.row || col >= start.col;
                let before_end = row < end.row || col < end.col;
                after_start && before_end
            });
            let style = if selected {
                span.style.bg(Color::DarkGray)
            } else {
                span.style
            };
            rendered.spans.push(Span::styled(ch.to_string(), style));
            global_col += 1;
        }
    }
    rendered
}

/// Lay `lines` out for a `width`-wide body: wrap each source line (when
/// wrapping is on), prefix the line-number gutter (blank on continuation
/// rows, like an editor), and pad tinted diff rows to the full width.
fn build_rows(lines: &[Line<'static>], numbered: bool, wrap: bool, width: u16) -> Vec<Row> {
    let number_width = lines.len().to_string().len();
    let gutter = if numbered { number_width + 1 } else { 0 };
    let content = usize::from(width).saturating_sub(gutter);
    let mut rows = Vec::with_capacity(lines.len());
    for (src, line) in lines.iter().enumerate() {
        let contains_tab = line.spans.iter().any(|span| span.content.contains('\t'));
        let pieces = if content > 0 && contains_tab {
            crate::wrap::wrap_line(line, if wrap { content } else { usize::MAX })
        } else if wrap && content > 0 && line.width() > content {
            crate::wrap::wrap_line(line, content)
        } else {
            vec![line.clone()]
        };
        for (i, piece) in pieces.into_iter().enumerate() {
            let mut row = piece;
            if numbered {
                // The number sits on the first row only; continuations
                // indent to the same column so the code stays aligned.
                let label = if i == 0 {
                    format!("{:>number_width$} ", src + 1)
                } else {
                    " ".repeat(gutter)
                };
                let style = row.style;
                let mut spans = vec![Span::styled(label, Style::default().dim())];
                spans.append(&mut row.spans);
                row = Line::from(spans);
                row.style = style;
            }
            // Tinted diff rows fill the full row, like an editor — every
            // row, so a wrapped change keeps its colour to the pane edge.
            if row.style.bg.is_some() {
                let pad = usize::from(width).saturating_sub(row.width());
                if pad > 0 {
                    row.spans.push(Span::raw(" ".repeat(pad)));
                }
            }
            rows.push(Row { src, line: row });
        }
    }
    rows
}

fn load(request: &Request) -> Doc {
    match request {
        Request::Close => Doc {
            name: "Preview".into(),
            context: String::new(),
            lines: vec![Line::raw("(closing)")],
            numbered: false,
            scroll: 0,
            wrap: true,
            rows: Vec::new(),
            rows_key: None,
            pending_src: None,
            selection: PreviewSelection::default(),
        },
        Request::File(path) => load_file(path),
        Request::Diff { root, rel, kind } => load_diff(root, rel, kind),
        Request::Show { root, spec, path } => load_show(root, spec, path.as_deref()),
    }
}

fn apply_diff_refresh(doc: &mut Doc, mut refreshed: Doc) {
    if doc.name == refreshed.name
        && doc.context == refreshed.context
        && doc.numbered == refreshed.numbered
        && doc.lines == refreshed.lines
    {
        return;
    }
    refreshed.wrap = doc.wrap;
    refreshed.pending_src = Some(doc.top_src());
    *doc = refreshed;
}

enum ViewMode {
    Preview(Doc),
    Edit(Editor),
}

#[derive(Clone)]
enum Pending {
    Close,
    LeaveEdit,
    Switch(Request),
}

enum Prompt {
    Unsaved(Pending),
    Conflict(Option<Pending>),
}

impl Prompt {
    fn text(&self) -> &'static str {
        match self {
            Self::Unsaved(_) => " Unsaved changes: [s] save  [d] discard  [Esc] cancel",
            Self::Conflict(_) => {
                " File changed on disk: [o] overwrite  [r] reload disk version  [Esc] cancel"
            }
        }
    }
}

fn mode_pane_label(mode: &ViewMode) -> String {
    match mode {
        ViewMode::Preview(doc) => preview_pane_label(&doc.name),
        ViewMode::Edit(editor) => editor_pane_label(&editor.name()),
    }
}

fn apply_pending(
    pending: Pending,
    mode: &mut ViewMode,
    current: &mut Option<Request>,
    control: &Path,
) -> bool {
    match pending {
        Pending::Close => {
            close_own_pane(control);
            true
        }
        Pending::LeaveEdit => {
            if let Some(request) = current.as_ref() {
                *mode = ViewMode::Preview(load(request));
                report_identity(mode, Some(&request.doc_key()), control);
            }
            false
        }
        Pending::Switch(request) => {
            if request == Request::Close {
                close_own_pane(control);
                true
            } else {
                *mode = ViewMode::Preview(load(&request));
                *current = Some(request);
                report_identity(
                    mode,
                    current.as_ref().map(Request::doc_key).as_deref(),
                    control,
                );
                false
            }
        }
    }
}

fn restore_current_control(control: &Path, current: &Option<Request>) {
    if let Some(request) = current {
        let _ = write_scratch_file(control, &request_payload(request));
    }
}

/// `git show` with stat + patch, colored — what a click on a commit, stash,
/// tag, or branch line renders. Immutable content: no refresh loop needed.
fn load_show(root: &Path, spec: &str, path: Option<&str>) -> Doc {
    let mut args: Vec<String> = vec![
        "-c".into(),
        "color.ui=always".into(),
        "show".into(),
        "--color=always".into(),
        "--stat".into(),
        "--patch".into(),
        "--no-ext-diff".into(),
        spec.to_string(),
    ];
    if let Some(p) = path {
        args.push("--".into());
        args.push(p.replace('/', std::path::MAIN_SEPARATOR_STR));
    }
    let output = std::process::Command::new("git")
        .args(&args)
        .current_dir(root)
        .output();
    let lines = match output {
        Err(e) => vec![Line::raw(format!("(git failed: {e})"))],
        Ok(out) => {
            let text = String::from_utf8_lossy(&out.stdout);
            if text.trim().is_empty() {
                let err = String::from_utf8_lossy(&out.stderr);
                if err.trim().is_empty() {
                    vec![Line::raw("(nothing to show)")]
                } else {
                    vec![Line::raw(format!("({})", err.trim()))]
                }
            } else {
                ansi::to_lines(&text)
            }
        }
    };
    Doc {
        name: spec.to_string(),
        context: format!("git show {spec} — {}", root.display()),
        lines,
        numbered: false,
        scroll: 0,
        wrap: true,
        rows: Vec::new(),
        rows_key: None,
        pending_src: None,
        selection: PreviewSelection::default(),
    }
}

/// Render markdown text via `glow`. Returns `None` when glow is not installed
/// or exits non-zero (caller falls back to syntax highlight).
///
/// Receives the already-read `text` buffer so the MAX_BYTES guard in
/// `load_file` is honoured — glow would otherwise re-read the full file.
/// Pipes via stdin (`-`) to avoid treating filenames starting with `-` as
/// flags. Width is a best-effort approximation; the ideal fix would pass
/// `body.width` from `draw_doc` once that is available at load time.
fn glow_markdown(text: &str, width: u16) -> Option<Vec<Line<'static>>> {
    use std::io::Write as _;
    let mut child = std::process::Command::new("glow")
        .args(["--style", "dark", "--width", &width.to_string(), "-"])
        .env("CLICOLOR_FORCE", "1")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;
    if let Some(stdin) = child.stdin.take() {
        let mut stdin = stdin;
        let _ = stdin.write_all(text.as_bytes());
    }
    let output = child.wait_with_output().ok()?;
    if !output.status.success() {
        return None;
    }
    let rendered = String::from_utf8_lossy(&output.stdout);
    if rendered.trim().is_empty() {
        return None;
    }
    let mut lines = ansi::to_lines(&rendered);
    lines.truncate(MAX_LINES);
    if lines.is_empty() {
        return None;
    }
    Some(lines)
}

fn load_file(target: &Path) -> Doc {
    let name = target
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| target.display().to_string());
    let lower = name.to_lowercase();
    let is_markdown = lower.ends_with(".md") || lower.ends_with(".markdown");
    let (lines, numbered) = match std::fs::read(target) {
        Err(e) => (vec![Line::raw(format!("(unreadable: {e})"))], true),
        Ok(bytes) => {
            if bytes.contains(&0) {
                (
                    vec![Line::raw(format!("(binary file — {} bytes)", bytes.len()))],
                    false,
                )
            } else {
                let truncated = bytes.len() > MAX_BYTES;
                let text = String::from_utf8_lossy(&bytes[..bytes.len().min(MAX_BYTES)]);
                // Markdown: render via glow; fall back to syntax highlight on failure.
                // Width is approximated by subtracting 6 for the sidebar share and
                // line-number gutter; ideal fix is to pass body.width from draw_doc.
                let glow_width = crossterm::terminal::size()
                    .map(|(w, _)| w.saturating_sub(6))
                    .unwrap_or(74);
                let glow_rendered = is_markdown
                    .then(|| glow_markdown(&text, glow_width))
                    .flatten();
                // Glow-rendered markdown gets no line numbers (it formats its own layout).
                let numbered = glow_rendered.is_none();
                let mut lines: Vec<Line<'static>> = if let Some(rendered) = glow_rendered {
                    rendered
                } else {
                    crate::syntax::highlight(&name, &text, MAX_LINES).unwrap_or_else(|| {
                        text.lines()
                            .take(MAX_LINES)
                            .map(|l| Line::raw(l.to_string()))
                            .collect()
                    })
                };
                if truncated || text.lines().count() > MAX_LINES {
                    lines.push(Line::raw("… (truncated)"));
                }
                if lines.is_empty() {
                    lines.push(Line::raw("(empty file)"));
                }
                (lines, numbered)
            }
        }
    };
    Doc {
        name,
        context: target.display().to_string(),
        lines,
        numbered,
        scroll: 0,
        wrap: true,
        rows: Vec::new(),
        rows_key: None,
        pending_src: None,
        selection: PreviewSelection::default(),
    }
}

fn load_diff(root: &Path, rel: &str, kind: &str) -> Doc {
    let name = rel.rsplit('/').next().unwrap_or(rel).to_string();
    // Plain (uncolored) diff: crate::diffview parses it and renders the
    // VS Code look — dual gutters, tinted rows, syntax-highlighted code.
    let mut args: Vec<String> = vec!["diff".into(), "--no-ext-diff".into()];
    match kind {
        "staged" => args.push("--cached".into()),
        // An untracked file has no diff; --no-index against the null device
        // renders it as one big addition, like VS Code does.
        "untracked" => {
            args.push("--no-index".into());
            args.push(if cfg!(windows) {
                "NUL".into()
            } else {
                "/dev/null".into()
            });
        }
        _ => {}
    }
    args.push("--".into());
    args.push(rel.replace('/', std::path::MAIN_SEPARATOR_STR));

    let output = std::process::Command::new("git")
        .args(&args)
        .current_dir(root)
        .output();
    let lines = match output {
        Err(e) => vec![Line::raw(format!("(git failed: {e})"))],
        Ok(out) => {
            // --no-index exits 1 when the files differ; that's not an error.
            let text = String::from_utf8_lossy(&out.stdout);
            if text.trim().is_empty() {
                let err = String::from_utf8_lossy(&out.stderr);
                if err.trim().is_empty() {
                    vec![Line::raw("(no changes)")]
                } else {
                    vec![Line::raw(format!("({})", err.trim()))]
                }
            } else {
                crate::diffview::render(rel, &text)
            }
        }
    };
    let what = match kind {
        "staged" => "staged",
        "untracked" => "untracked",
        _ => "working tree",
    };
    Doc {
        name: name.clone(),
        context: format!("{} — {what} diff", root.join(rel).display()),
        lines,
        numbered: false,
        scroll: 0,
        wrap: true,
        rows: Vec::new(),
        rows_key: None,
        pending_src: None,
        selection: PreviewSelection::default(),
    }
}

fn read_control(control: &Path) -> Option<Request> {
    let mut buf = String::new();
    std::fs::File::open(control)
        .ok()?
        .read_to_string(&mut buf)
        .ok()?;
    parse_request(&buf)
}

/// Tag our pane (heartbeat-stamped, see launch::HEARTBEAT_STALE_SECS), record
/// WHICH document we show so any sidebar can route clicks to us, and title the
/// pane with the document's name. A `None` key clears the token — showing
/// nothing must not look like a preview of the empty path.
fn report_identity(mode: &ViewMode, doc_key: Option<&str>, control: &Path) {
    let Ok(pane_id) = std::env::var("HERDR_PANE_ID") else {
        return;
    };
    if pane_id.is_empty() {
        return;
    }
    let doc_token = doc_key.map(document_token);
    let control_token = control_token(control);
    let _ = ipc::call_text(
        "pane.report_metadata",
        serde_json::json!({
            "pane_id": pane_id,
            "source": METADATA_SOURCE,
            "tokens": {
                METADATA_SOURCE: crate::state::unix_now().to_string(),
                TOKEN_PATH: doc_token,
                TOKEN_CONTROL: control_token,
                TOKEN_DEDICATED: "1",
            },
        }),
    );
    let _ = ipc::call_text(
        "pane.rename",
        serde_json::json!({ "pane_id": pane_id, "label": mode_pane_label(mode) }),
    );
    let Some(doc_key) = doc_key else { return };
    if let Ok(list) = ipc::call_text("pane.list", serde_json::json!({}))
        && let Some(preview) = previews_in(&list)
            .into_iter()
            .find(|p| p.pane_id == pane_id)
    {
        let _ = ipc::call_text(
            "tab.rename",
            serde_json::json!({
                "tab_id": preview.tab_id,
                "label": tab_label(doc_key, preview.pinned),
            }),
        );
    }
}

fn preview_pane_label(doc_name: &str) -> String {
    format!("{doc_name} · preview")
}

fn editor_pane_label(doc_name: &str) -> String {
    format!("{doc_name} · editor")
}

/// Close the whole preview tab. Closing only the viewer pane leaves its
/// auto-docked sidebar behind as a convincing but unusable preview husk.
fn close_own_pane(control: &Path) {
    let Ok(pane_id) = std::env::var("HERDR_PANE_ID") else {
        return;
    };
    if pane_id.is_empty() {
        return;
    }
    let list = ipc::call_text("pane.list", serde_json::json!({})).ok();
    let preview = list.as_deref().and_then(|json| {
        previews_in(json)
            .into_iter()
            .find(|preview| preview.pane_id == pane_id)
    });
    let _ = std::fs::remove_file(control);
    let _ = std::fs::remove_file(control_path_for_pane(&pane_id));
    if let Some(preview) = preview.filter(|preview| {
        preview.dedicated
            && list
                .as_deref()
                .is_some_and(|json| tab_is_plugin_only(json, &preview.tab_id))
    }) {
        close_preview_tab(&preview);
    } else {
        let _ = ipc::call_text("pane.close", serde_json::json!({ "pane_id": pane_id }));
    }
}

fn close_preview_tab(preview: &PreviewPane) {
    // Focus first: closing our own tab kills this process, so code after a
    // successful tab.close is not guaranteed to run.
    if !preview.origin_tab_id.is_empty() {
        let _ = ipc::call_text(
            "tab.focus",
            serde_json::json!({ "tab_id": preview.origin_tab_id }),
        );
    }
    let _ = ipc::call_text("tab.close", serde_json::json!({ "tab_id": preview.tab_id }));
}

fn pin_own_tab(doc_key: &str) {
    let Ok(pane_id) = std::env::var("HERDR_PANE_ID") else {
        return;
    };
    let Ok(list) = ipc::call_text("pane.list", serde_json::json!({})) else {
        return;
    };
    let tab_id = crate::launch::tab_of(&list, &pane_id);
    if pane_id.is_empty() || tab_id.is_empty() {
        return;
    }
    let _ = ipc::call_text(
        "pane.report_metadata",
        serde_json::json!({
            "pane_id": pane_id,
            "source": METADATA_SOURCE,
            "tokens": { TOKEN_PINNED: "1" },
        }),
    );
    let _ = ipc::call_text(
        "tab.rename",
        serde_json::json!({ "tab_id": tab_id, "label": tab_label(doc_key, true) }),
    );
}

/// Delete control files whose pane is gone. `close_own_pane` handles the
/// clean exit; this catches previews killed from outside (pane closed by
/// herdr, redeploy, server restart), which never get to run their own
/// cleanup. Cheap: one readdir against a `pane.list` we already have.
fn sweep_orphan_controls(pane_list_json: &str) {
    let previews = previews_in(pane_list_json);
    let live: std::collections::BTreeSet<String> = previews
        .iter()
        .filter(|preview| !preview.stale)
        .map(|preview| preview.pane_id.replace(':', "_"))
        .collect();
    let live_controls: std::collections::BTreeSet<PathBuf> = previews
        .into_iter()
        .filter(|preview| !preview.stale)
        .map(|preview| preview.control)
        .collect();
    let Ok(entries) = std::fs::read_dir(scratch_dir()) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if live_controls.contains(&entry.path()) {
            continue;
        }
        let legacy_orphan = name
            .strip_prefix("herdr-sidebar-preview-")
            .and_then(|value| value.strip_suffix(".ctl"))
            .is_some_and(|id| !live.contains(id));
        let abandoned_spawn = (name.starts_with("herdr-sidebar-control-")
            || name.starts_with("p-"))
            && entry
                .metadata()
                .ok()
                .and_then(|metadata| metadata.modified().ok())
                .and_then(|modified| modified.elapsed().ok())
                .is_some_and(|age| age >= Duration::from_secs(60));
        if legacy_orphan || abandoned_spawn {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

/// The viewer's event loop; returns when the user closes it.
pub fn run(control: &Path) -> std::io::Result<()> {
    let theme = IconTheme::resolve(
        std::env::var("HERDR_SIDEBAR_ICONS")
            .or_else(|_| std::env::var("HERDR_AA_FILETREE_ICONS"))
            .ok()
            .as_deref(),
        crate::state::load_state().icons,
    );
    let mut current = read_control(control);
    let doc = current.as_ref().map(load).unwrap_or_else(|| Doc {
        name: "(nothing to show)".into(),
        context: String::new(),
        lines: vec![Line::raw("(waiting for a click in the sidebar)")],
        numbered: false,
        scroll: 0,
        wrap: true,
        rows: Vec::new(),
        rows_key: None,
        pending_src: None,
        selection: PreviewSelection::default(),
    });
    let mut mode = ViewMode::Preview(doc);
    report_identity(
        &mode,
        current.as_ref().map(Request::doc_key).as_deref(),
        control,
    );

    // Blank the primary screen so pane handoffs never flash the shell.
    let _ = crossterm::execute!(
        std::io::stdout(),
        crossterm::terminal::Clear(crossterm::terminal::ClearType::All),
        crossterm::terminal::Clear(crossterm::terminal::ClearType::Purge),
        crossterm::cursor::MoveTo(0, 0),
    );
    crossterm::style::force_color_output(true); // TUI colors ≠ pipeable output
    let mut terminal = ratatui::init();
    let _ = crossterm::execute!(std::io::stdout(), EnableMouseCapture);
    let mut page: usize = 20;
    let mut preview_body = Rect::default();
    let mut edit_width: usize = 1;
    let mut edit_body = Rect::default();
    let mut prompt: Option<Prompt> = None;
    let mut notice: Option<String> = None;
    let mut last_heartbeat = Instant::now();
    let mut last_external_check = Instant::now();
    let mut last_diff_refresh = Instant::now();
    let mut diff_refresh: Option<(Request, std::sync::mpsc::Receiver<Doc>)> = None;
    let result = loop {
        let prompt_text = prompt.as_ref().map(Prompt::text);
        let draw = terminal.draw(|frame| match &mut mode {
            ViewMode::Preview(doc) => {
                (page, preview_body) = draw_doc(
                    frame,
                    doc,
                    theme,
                    matches!(current, Some(Request::File(_))),
                    notice.as_deref(),
                );
            }
            ViewMode::Edit(editor) => {
                (page, edit_width, edit_body) = draw_editor(frame, editor, theme, prompt_text);
            }
        });
        if let Err(e) = draw {
            break Err(e);
        }
        let mut should_close = false;
        if event::poll(POLL)? {
            match event::read()? {
                Event::Key(key) if key.kind == KeyEventKind::Press => {
                    if let Some(active_prompt) = prompt.take() {
                        match (active_prompt, key.code) {
                            (Prompt::Unsaved(pending), KeyCode::Char('s')) => {
                                if let ViewMode::Edit(editor) = &mut mode {
                                    match editor.save(false) {
                                        Ok(SaveOutcome::Saved) => {
                                            should_close = apply_pending(
                                                pending,
                                                &mut mode,
                                                &mut current,
                                                control,
                                            );
                                        }
                                        Ok(SaveOutcome::Conflict) => {
                                            prompt = Some(Prompt::Conflict(Some(pending)));
                                        }
                                        Err(e) => {
                                            editor.set_status(format!("save failed: {e}"));
                                            prompt = Some(Prompt::Unsaved(pending));
                                        }
                                    }
                                }
                            }
                            (Prompt::Unsaved(pending), KeyCode::Char('d')) => {
                                should_close =
                                    apply_pending(pending, &mut mode, &mut current, control);
                            }
                            (Prompt::Unsaved(_), KeyCode::Esc | KeyCode::Char('c')) => {
                                restore_current_control(control, &current);
                                report_identity(
                                    &mode,
                                    current.as_ref().map(Request::doc_key).as_deref(),
                                    control,
                                );
                            }
                            (Prompt::Conflict(after), KeyCode::Char('o')) => {
                                if let ViewMode::Edit(editor) = &mut mode {
                                    match editor.save(true) {
                                        Ok(SaveOutcome::Saved) => {
                                            if let Some(pending) = after {
                                                should_close = apply_pending(
                                                    pending,
                                                    &mut mode,
                                                    &mut current,
                                                    control,
                                                );
                                            }
                                        }
                                        Ok(SaveOutcome::Conflict) => unreachable!(),
                                        Err(e) => {
                                            editor.set_status(format!("save failed: {e}"));
                                            prompt = Some(Prompt::Conflict(after));
                                        }
                                    }
                                }
                            }
                            (Prompt::Conflict(after), KeyCode::Char('r')) => {
                                if let ViewMode::Edit(editor) = &mut mode {
                                    match editor.reload(MAX_BYTES, MAX_LINES) {
                                        Ok(()) => {
                                            if let Some(pending) = after {
                                                should_close = apply_pending(
                                                    pending,
                                                    &mut mode,
                                                    &mut current,
                                                    control,
                                                );
                                            }
                                        }
                                        Err(e) => {
                                            editor.set_status(e.to_string());
                                            prompt = Some(Prompt::Conflict(after));
                                        }
                                    }
                                }
                            }
                            (Prompt::Conflict(_), KeyCode::Esc | KeyCode::Char('c')) => {
                                restore_current_control(control, &current);
                                report_identity(
                                    &mode,
                                    current.as_ref().map(Request::doc_key).as_deref(),
                                    control,
                                );
                            }
                            (active, _) => prompt = Some(active),
                        }
                    } else {
                        match &mut mode {
                            ViewMode::Preview(doc) => {
                                let max = doc.rows.len().saturating_sub(1);
                                let shortcut = (key.modifiers.contains(KeyModifiers::CONTROL)
                                    && !key.modifiers.contains(KeyModifiers::ALT))
                                    || key.modifiers.contains(KeyModifiers::SUPER);
                                match key.code {
                                    KeyCode::Char('a') if shortcut => doc.select_all(),
                                    KeyCode::Char('c') if shortcut => {
                                        notice = Some(match doc.selected_text() {
                                            Some(text) => {
                                                match crate::actions::copy_to_clipboard(&text) {
                                                    Ok(()) => "copied selection".into(),
                                                    Err(error) => {
                                                        format!("clipboard unavailable: {error}")
                                                    }
                                                }
                                            }
                                            None => "select text before copying".into(),
                                        });
                                    }
                                    KeyCode::Esc | KeyCode::Char('q') => {
                                        close_own_pane(control);
                                        should_close = true;
                                    }
                                    KeyCode::Char('e') => {
                                        if let Some(Request::File(path)) = current.as_ref() {
                                            match Editor::open(path, MAX_BYTES, MAX_LINES) {
                                                Ok(editor) => {
                                                    mode = ViewMode::Edit(editor);
                                                    notice = None;
                                                    report_identity(
                                                        &mode,
                                                        current
                                                            .as_ref()
                                                            .map(Request::doc_key)
                                                            .as_deref(),
                                                        control,
                                                    );
                                                }
                                                Err(e) => notice = Some(e.to_string()),
                                            }
                                        } else {
                                            notice = Some(
                                                "diffs and history previews are read-only".into(),
                                            );
                                        }
                                    }
                                    KeyCode::Up | KeyCode::Char('k') => {
                                        doc.scroll = doc.scroll.saturating_sub(1)
                                    }
                                    KeyCode::Down | KeyCode::Char('j') => {
                                        doc.scroll = (doc.scroll + 1).min(max)
                                    }
                                    KeyCode::PageUp => doc.scroll = doc.scroll.saturating_sub(page),
                                    KeyCode::PageDown => doc.scroll = (doc.scroll + page).min(max),
                                    KeyCode::Home | KeyCode::Char('g') => doc.scroll = 0,
                                    KeyCode::End | KeyCode::Char('G') => doc.scroll = max,
                                    KeyCode::Char('w') => {
                                        doc.pending_src = Some(doc.top_src());
                                        doc.wrap = !doc.wrap;
                                    }
                                    _ => {}
                                }
                            }
                            ViewMode::Edit(editor) => {
                                let was_dirty = editor.dirty;
                                let action = editor.on_key(key, edit_width, page);
                                if !was_dirty
                                    && editor.dirty
                                    && let Some(doc_key) = current.as_ref().map(Request::doc_key)
                                {
                                    pin_own_tab(&doc_key);
                                }
                                match action {
                                    EditAction::None => {}
                                    EditAction::Leave => {
                                        if editor.dirty {
                                            prompt = Some(Prompt::Unsaved(Pending::LeaveEdit));
                                        } else {
                                            should_close = apply_pending(
                                                Pending::LeaveEdit,
                                                &mut mode,
                                                &mut current,
                                                control,
                                            );
                                        }
                                    }
                                    EditAction::Close => {
                                        if editor.dirty {
                                            prompt = Some(Prompt::Unsaved(Pending::Close));
                                        } else {
                                            close_own_pane(control);
                                            should_close = true;
                                        }
                                    }
                                    EditAction::Save => match editor.save(false) {
                                        Ok(SaveOutcome::Saved) => notice = None,
                                        Ok(SaveOutcome::Conflict) => {
                                            prompt = Some(Prompt::Conflict(None))
                                        }
                                        Err(e) => editor.set_status(format!("save failed: {e}")),
                                    },
                                }
                            }
                        }
                    }
                }
                Event::Mouse(mouse) => match &mut mode {
                    ViewMode::Preview(doc) => {
                        let max = doc.rows.len().saturating_sub(1);
                        match mouse.kind {
                            MouseEventKind::ScrollUp => doc.scroll = doc.scroll.saturating_sub(3),
                            MouseEventKind::ScrollDown => doc.scroll = (doc.scroll + 3).min(max),
                            MouseEventKind::Down(MouseButton::Left)
                                if mouse.row == 0 && mouse.column < 3 =>
                            {
                                close_own_pane(control);
                                should_close = true;
                            }
                            _ => doc.on_mouse(&mouse, preview_body),
                        }
                    }
                    ViewMode::Edit(editor) => match mouse.kind {
                        MouseEventKind::ScrollUp => {
                            editor.scroll_by(-3, edit_width, page.saturating_add(1))
                        }
                        MouseEventKind::ScrollDown => {
                            editor.scroll_by(3, edit_width, page.saturating_add(1))
                        }
                        MouseEventKind::Down(MouseButton::Left)
                            if mouse.row == 0 && mouse.column < 3 =>
                        {
                            if editor.dirty {
                                prompt = Some(Prompt::Unsaved(Pending::Close));
                            } else {
                                close_own_pane(control);
                                should_close = true;
                            }
                        }
                        _ if prompt.is_none() => editor.on_mouse(&mouse, edit_body),
                        _ => {}
                    },
                },
                _ => {} // resize etc: redraw
            }
        }
        if should_close {
            break Ok(());
        }

        // These checks run after every iteration, including sustained input;
        // otherwise a held key can starve the liveness heartbeat indefinitely.
        if last_heartbeat.elapsed() >= Duration::from_secs(5) {
            report_identity(
                &mode,
                current.as_ref().map(Request::doc_key).as_deref(),
                control,
            );
            last_heartbeat = Instant::now();
        }
        if prompt.is_none() {
            let target = read_control(control);
            if target != current
                && let Some(request) = target
            {
                if let ViewMode::Edit(editor) = &mode
                    && editor.dirty
                {
                    prompt = Some(Prompt::Unsaved(Pending::Switch(request)));
                } else if request == Request::Close {
                    close_own_pane(control);
                    break Ok(());
                } else {
                    mode = ViewMode::Preview(load(&request));
                    current = Some(request);
                    notice = None;
                    report_identity(
                        &mode,
                        current.as_ref().map(Request::doc_key).as_deref(),
                        control,
                    );
                }
            }
        }
        if last_external_check.elapsed() >= Duration::from_secs(2) {
            if let ViewMode::Edit(editor) = &mut mode {
                editor.poll_external(MAX_BYTES, MAX_LINES);
            }
            last_external_check = Instant::now();
        }
        let refreshed =
            diff_refresh
                .as_ref()
                .and_then(|(request, receiver)| match receiver.try_recv() {
                    Ok(doc) => Some((request.clone(), Some(doc))),
                    Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                        Some((request.clone(), None))
                    }
                    Err(std::sync::mpsc::TryRecvError::Empty) => None,
                });
        if let Some((request, refreshed)) = refreshed {
            diff_refresh = None;
            if current.as_ref() == Some(&request)
                && let (ViewMode::Preview(doc), Some(refreshed)) = (&mut mode, refreshed)
            {
                apply_diff_refresh(doc, refreshed);
            }
        }
        if last_diff_refresh.elapsed() >= Duration::from_secs(2) {
            if diff_refresh.is_none()
                && matches!(mode, ViewMode::Preview(_))
                && let Some(request @ Request::Diff { .. }) = current.clone()
            {
                let worker_request = request.clone();
                let (sender, receiver) = std::sync::mpsc::channel();
                std::thread::spawn(move || {
                    let _ = sender.send(load(&worker_request));
                });
                diff_refresh = Some((request, receiver));
            }
            last_diff_refresh = Instant::now();
        }
    };
    let _ = crossterm::execute!(std::io::stdout(), DisableMouseCapture);
    ratatui::restore();
    result
}

/// Header (✕ close + name + context), body, hint footer. Returns the page
/// stride for PageUp/Down.
fn draw_doc(
    frame: &mut Frame,
    doc: &mut Doc,
    theme: IconTheme,
    editable: bool,
    notice: Option<&str>,
) -> (usize, Rect) {
    let area = frame.area();
    let [header, body, footer] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(0),
        Constraint::Length(1),
    ])
    .areas(area);

    // Lay the body out for THIS width first: everything below (the clamp,
    // the slice, the page stride) counts rendered rows.
    doc.relayout(body.width);
    doc.scroll = doc.scroll.min(
        doc.rows
            .len()
            .saturating_sub(usize::from(body.height).max(1)),
    );

    let file_icon = icon(theme, &doc.name, false, false);
    let icon_style = match file_icon.rgb {
        Some((r, g, b)) => Style::default().fg(Color::Rgb(r, g, b)),
        None => Style::default(),
    };
    let left = vec![
        Span::styled(" ✕ ", Style::default().bold().fg(Color::LightBlue)),
        Span::styled(format!("{} ", file_icon.glyph), icon_style),
        Span::styled(doc.name.clone(), Style::default().bold()),
    ];
    let used: usize = left.iter().map(Span::width).sum();
    let avail = usize::from(area.width).saturating_sub(used + 2);
    let shown = if doc.context.chars().count() > avail {
        let tail: String = doc
            .context
            .chars()
            .skip(
                doc.context
                    .chars()
                    .count()
                    .saturating_sub(avail.saturating_sub(1)),
            )
            .collect();
        format!("…{tail}")
    } else {
        doc.context.clone()
    };
    let mut spans = left;
    spans.push(Span::styled(format!("  {shown}"), Style::default().dim()));
    frame.render_widget(Paragraph::new(Line::from(spans)), header);

    // Rows are pre-wrapped, so the Paragraph never wraps for us: its
    // continuations would render past the bottom of the pane, where no
    // amount of scrolling could reach them.
    let selection = doc.selection_range();
    let gutter = doc.gutter();
    let text: Vec<Line> = doc
        .rows
        .iter()
        .enumerate()
        .skip(doc.scroll)
        .take(usize::from(body.height))
        .map(|(row, rendered)| selected_row(&rendered.line, gutter, row, selection))
        .collect();
    frame.render_widget(Paragraph::new(text), body);

    let wrap_hint = if doc.wrap {
        "w: wrap on"
    } else {
        "w: wrap off"
    };
    let hint = if let Some(notice) = notice {
        format!(" {notice}")
    } else if editable {
        format!(" drag select  Ctrl/Cmd+C copy  e edit  {wrap_hint}  q close")
    } else {
        format!(" drag select  Ctrl/Cmd+C copy  ↑↓ scroll  {wrap_hint}  q close")
    };
    frame.render_widget(Paragraph::new(Line::from(hint).dim()), footer);
    (usize::from(body.height).saturating_sub(1).max(1), body)
}

fn draw_editor(
    frame: &mut Frame,
    editor: &mut Editor,
    theme: IconTheme,
    prompt: Option<&str>,
) -> (usize, usize, Rect) {
    let area = frame.area();
    let [header, body, footer] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(0),
        Constraint::Length(1),
    ])
    .areas(area);
    let name = editor.name();
    let file_icon = icon(theme, &name, false, false);
    let icon_style = match file_icon.rgb {
        Some((r, g, b)) => Style::default().fg(Color::Rgb(r, g, b)),
        None => Style::default(),
    };
    let dirty = if editor.dirty { " ●" } else { "" };
    let external = if editor.external_changed {
        "  EXTERNAL CHANGE"
    } else {
        ""
    };
    let left = vec![
        Span::styled(" ✕ ", Style::default().bold().fg(Color::LightBlue)),
        Span::styled(format!("{} ", file_icon.glyph), icon_style),
        Span::styled(format!("{name}{dirty}"), Style::default().bold()),
        Span::styled("  EDIT (experimental)", Style::default().fg(Color::Yellow)),
        Span::styled(external, Style::default().fg(Color::LightRed).bold()),
    ];
    let used: usize = left.iter().map(Span::width).sum();
    let context = editor.context();
    let avail = usize::from(area.width).saturating_sub(used + 2);
    let shown = if context.chars().count() > avail {
        let tail: String = context
            .chars()
            .skip(
                context
                    .chars()
                    .count()
                    .saturating_sub(avail.saturating_sub(1)),
            )
            .collect();
        format!("…{tail}")
    } else {
        context
    };
    let mut spans = left;
    spans.push(Span::styled(format!("  {shown}"), Style::default().dim()));
    frame.render_widget(Paragraph::new(Line::from(spans)), header);
    editor.draw(frame, body, footer, prompt);
    let gutter = editor.line_count().to_string().len() + 1;
    (
        usize::from(body.height).saturating_sub(1).max(1),
        usize::from(body.width).saturating_sub(gutter).max(1),
        body,
    )
}

// ---------------------------------------------------------------------------
// Client side: how the sidebar views open things in the viewer pane.
// ---------------------------------------------------------------------------

/// Open `payload` (identified by `doc_key`) following VS Code tab rules:
/// jump to the document's existing tab, else overwrite the one ephemeral
/// tab, else create a tab for it.
pub fn open_in_pane(
    my_pane_id: &str,
    spawn_cwd: &Path,
    doc_key: &str,
    payload: &str,
) -> Result<PreviewTarget, String> {
    let list = ipc::call_text("pane.list", serde_json::json!({}))
        .map_err(|e| format!("preview failed: {e}"))?;
    let caller_tab_id = crate::launch::tab_of(&list, my_pane_id);
    sweep_orphan_controls(&list);
    // Route only within OUR space. A session-wide search reused another
    // project's ephemeral tab and focus jumped there, which reads as the
    // tree refusing to change.
    let my_workspace = crate::launch::workspace_of(&list, my_pane_id);
    let mut previews: Vec<PreviewPane> = previews_in(&list)
        .into_iter()
        .filter(|p| p.workspace_id == my_workspace)
        .collect();
    for stale in previews.iter().filter(|preview| preview.stale) {
        let _ = std::fs::remove_file(&stale.control);
        if (stale.dedicated || stale.resumed) && tab_is_plugin_only(&list, &stale.tab_id) {
            let _ = ipc::call_text("tab.close", serde_json::json!({ "tab_id": stale.tab_id }));
        } else {
            let _ = ipc::call_text(
                "pane.close",
                serde_json::json!({ "pane_id": stale.pane_id }),
            );
        }
    }
    previews.retain(|preview| !preview.stale);
    previews.sort_by(|a, b| a.tab_id.cmp(&b.tab_id).then(a.pane_id.cmp(&b.pane_id)));
    let origin_tab_id = preview_origin_tab(&previews, &caller_tab_id);

    // 1. Already open — jump to it, pinned or not.
    if let Some(p) = preview_for_doc(&previews, doc_key) {
        remember_origin(&p.pane_id, &origin_tab_id);
        let _ = ipc::call_text("tab.focus", serde_json::json!({ "tab_id": p.tab_id }));
        return Ok(PreviewTarget {
            pane_id: p.pane_id,
            tab_id: p.tab_id,
            origin_tab_id,
        });
    }

    // 2. Overwrite the ephemeral tab.
    if let Some(p) = reusable_preview(&previews) {
        write_scratch_file(&p.control, payload).map_err(|e| format!("preview failed: {e}"))?;
        remember_origin(&p.pane_id, &origin_tab_id);
        let _ = ipc::call_text("tab.focus", serde_json::json!({ "tab_id": p.tab_id }));
        return Ok(PreviewTarget {
            pane_id: p.pane_id,
            tab_id: p.tab_id,
            origin_tab_id,
        });
    }

    // 3. Nothing reusable — a tab of its own.
    spawn_preview_tab(my_pane_id, spawn_cwd, doc_key, payload, &origin_tab_id)
}

/// Where a preview request landed. Handed back so a double click can pin
/// exactly the tab its first click used — searching by document key would
/// race the viewer, which only stamps `hs-preview-path` once it has started.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreviewTarget {
    pub pane_id: String,
    pub tab_id: String,
    pub origin_tab_id: String,
}

/// Mark a preview's tab pinned: wait briefly for a clean viewer to acknowledge
/// the first click, then stamp the token so it stops being reusable. Dirty
/// editors deliberately do not acknowledge a switch until the user resolves
/// their unsaved-change prompt. Idempotent.
pub fn pin_target(target: &PreviewTarget, doc_key: &str) -> bool {
    let deadline = Instant::now() + Duration::from_millis(800);
    loop {
        let Ok(list) = ipc::call_text("pane.list", serde_json::json!({})) else {
            return false;
        };
        if target_is_showing(&previews_in(&list), target, doc_key) {
            break;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let _ = ipc::call_text(
        "pane.report_metadata",
        serde_json::json!({
            "pane_id": target.pane_id,
            "source": METADATA_SOURCE,
            "tokens": { TOKEN_PINNED: "1" },
        }),
    );
    let _ = ipc::call_text(
        "tab.rename",
        serde_json::json!({ "tab_id": target.tab_id, "label": tab_label(doc_key, true) }),
    );
    true
}

fn target_is_showing(previews: &[PreviewPane], target: &PreviewTarget, doc_key: &str) -> bool {
    let expected = document_token(doc_key);
    previews.iter().any(|preview| {
        !preview.stale && preview.pane_id == target.pane_id && preview.doc_token == expected
    })
}

/// Spawn a preview and give it its own tab. The pane is split beside the
/// sidebar first and then MOVED out: `tab.create` would leave a stray shell
/// pane, and the move reuses the proven `pane.move` path. The `tab.created`
/// hook docks a sidebar alongside it, so the tree stays reachable.
fn spawn_preview_tab(
    my_pane_id: &str,
    spawn_cwd: &Path,
    doc_key: &str,
    payload: &str,
    origin_tab_id: &str,
) -> Result<PreviewTarget, String> {
    let (new_pane, control) = spawn_viewer_pane(my_pane_id, spawn_cwd, doc_key, payload)?;
    let moved = match ipc::call_text(
        "pane.move",
        serde_json::json!({
            "pane_id": new_pane,
            "destination": { "type": "new_tab", "label": tab_label(doc_key, false) },
            "focus": true,
        }),
    ) {
        Ok(response) => response,
        Err(error) => {
            cleanup_spawn(&new_pane, &control);
            return Err(format!("preview tab failed to open: {error}"));
        }
    };
    if !pane_move_changed(&moved) {
        cleanup_spawn(&new_pane, &control);
        return Err("preview tab failed to open".into());
    }
    let tab_id = ipc::call_text("pane.list", serde_json::json!({}))
        .map(|list| crate::launch::tab_of(&list, &new_pane))
        .unwrap_or_default();
    if tab_id.is_empty() {
        cleanup_spawn(&new_pane, &control);
        return Err("preview tab opened without a tab id".into());
    }
    if !mark_dedicated_preview(&new_pane) {
        cleanup_moved_spawn(&new_pane, &tab_id, &control);
        return Err("preview tab could not record ownership".into());
    }
    remember_origin(&new_pane, origin_tab_id);
    if !start_viewer_pane(&new_pane) {
        cleanup_moved_spawn(&new_pane, &tab_id, &control);
        return Err("preview process failed to start".into());
    }
    Ok(PreviewTarget {
        pane_id: new_pane,
        tab_id,
        origin_tab_id: origin_tab_id.to_string(),
    })
}

fn remember_origin(pane_id: &str, tab_id: &str) {
    if tab_id.is_empty() {
        return;
    }
    let _ = ipc::call_text(
        "pane.report_metadata",
        serde_json::json!({
            "pane_id": pane_id,
            "source": METADATA_SOURCE,
            "tokens": { TOKEN_ORIGIN_TAB: tab_id },
        }),
    );
}

/// Ask this tab's viewer to close (Esc from the sidebar). A live viewer owns
/// the close so an editor with unsaved changes can confirm first; only a stale
/// resumed pane is killed directly.
pub fn close_in_tab(my_pane_id: &str) {
    let Ok(json) = ipc::call_text("pane.list", serde_json::json!({})) else {
        return;
    };
    if let Some((id, stale)) = viewer_pane_in_tab(&json, my_pane_id) {
        if stale {
            if let Some(preview) = previews_in(&json)
                .into_iter()
                .find(|preview| preview.pane_id == id)
                && (preview.dedicated || preview.resumed)
                && tab_is_plugin_only(&json, &preview.tab_id)
            {
                close_preview_tab(&preview);
            } else {
                let _ = ipc::call_text("pane.close", serde_json::json!({ "pane_id": id }));
            }
        } else {
            let control = previews_in(&json)
                .into_iter()
                .find(|preview| preview.pane_id == id)
                .map(|preview| preview.control)
                .unwrap_or_else(|| control_path_for_pane(&id));
            let _ = write_scratch_file(&control, "close");
        }
    }
}

/// The viewer pane in the same tab, by metadata token, plus whether its
/// heartbeat says it is DEAD (`(pane_id, stale)`).
fn viewer_pane_in_tab(pane_list_json: &str, my_pane_id: &str) -> Option<(String, bool)> {
    #[derive(serde::Deserialize)]
    struct Msg {
        result: Res,
    }
    #[derive(serde::Deserialize)]
    struct Res {
        #[serde(default)]
        panes: Vec<Pane>,
    }
    #[derive(serde::Deserialize)]
    struct Pane {
        pane_id: Option<String>,
        tab_id: Option<String>,
        label: Option<String>,
        #[serde(default)]
        tokens: serde_json::Map<String, serde_json::Value>,
    }
    let msg: Msg = serde_json::from_str(pane_list_json.trim_start_matches('\u{feff}')).ok()?;
    let panes = &msg.result.panes;
    let my_tab = panes
        .iter()
        .find(|p| p.pane_id.as_deref() == Some(my_pane_id))?
        .tab_id
        .clone()?;
    // Token match finds a live viewer; a preview-labelled pane WITHOUT the
    // token is a resumed corpse (labels survive server restarts, tokens
    // don't) — report it too, with a missing token, so the stale check
    // below flags it and the caller closes it instead of spawning a twin.
    let viewer = panes
        .iter()
        .filter(|p| p.tab_id.as_deref() == Some(my_tab.as_str()))
        .find(|p| {
            p.tokens.contains_key(METADATA_SOURCE)
                || p.label
                    .as_deref()
                    .is_some_and(crate::launch::is_preview_label)
        })?;
    let id = viewer.pane_id.clone()?;
    let now = crate::state::unix_now();
    let stale = viewer
        .tokens
        .get(METADATA_SOURCE)
        .and_then(|v| v.as_str())
        .and_then(|s| s.parse::<u64>().ok())
        .map(|ts| now.saturating_sub(ts) > crate::launch::HEARTBEAT_STALE_SECS)
        .unwrap_or(true);
    Some((id, stale))
}

pub const TOKEN_PATH: &str = "hs-preview-path";
pub const TOKEN_PINNED: &str = "hs-preview-pinned";
pub const TOKEN_CONTROL: &str = "hs-preview-control";
pub const TOKEN_DEDICATED: &str = "hs-preview-dedicated";
pub const TOKEN_ORIGIN_TAB: &str = "hs-preview-origin-tab";

/// A live preview pane and the document it is showing. State lives on the
/// pane, so it cannot outlive what it describes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreviewPane {
    pub pane_id: String,
    pub tab_id: String,
    /// The space this preview belongs to. Routing is scoped to it: the
    /// ephemeral tab is per project, and reusing another workspace's would
    /// yank focus into a different project.
    pub workspace_id: String,
    pub doc_token: String,
    pub pinned: bool,
    pub control: PathBuf,
    pub stale: bool,
    pub dedicated: bool,
    pub origin_tab_id: String,
    /// Herdr restored the pane label but not its process metadata. This is a
    /// dead shell left behind by server resume, not a live unsaved editor.
    pub resumed: bool,
}

/// Every preview pane in the session, from one `pane.list` payload.
fn previews_in(pane_list_json: &str) -> Vec<PreviewPane> {
    #[derive(serde::Deserialize)]
    struct Msg {
        result: Res,
    }
    #[derive(serde::Deserialize)]
    struct Res {
        #[serde(default)]
        panes: Vec<Pane>,
    }
    #[derive(serde::Deserialize)]
    struct Pane {
        pane_id: Option<String>,
        tab_id: Option<String>,
        workspace_id: Option<String>,
        label: Option<String>,
        #[serde(default)]
        tokens: std::collections::BTreeMap<String, serde_json::Value>,
    }
    let Ok(msg) = serde_json::from_str::<Msg>(crate::launch::strip_bom(pane_list_json)) else {
        return Vec::new();
    };
    msg.result
        .panes
        .into_iter()
        .filter_map(|p| {
            let preview_label = p
                .label
                .as_deref()
                .is_some_and(crate::launch::is_preview_label);
            let raw_doc_token = p.tokens.get(TOKEN_PATH).and_then(|value| value.as_str());
            if raw_doc_token.is_none() && !preview_label {
                return None;
            }
            let doc_token = raw_doc_token
                .map(|raw| {
                    if raw.len() == 16 && raw.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                        raw.to_string()
                    } else {
                        document_token(raw)
                    }
                })
                .unwrap_or_default();
            let pane_id = p.pane_id?;
            let control = p
                .tokens
                .get(TOKEN_CONTROL)
                .and_then(|value| value.as_str())
                .map(control_from_token)
                .unwrap_or_else(|| control_path_for_pane(&pane_id));
            let heartbeat = p
                .tokens
                .get(METADATA_SOURCE)
                .and_then(|value| value.as_str())
                .and_then(|value| value.parse::<u64>().ok());
            let resumed = preview_label && heartbeat.is_none();
            let stale = heartbeat
                .map(|stamp| {
                    crate::state::unix_now().saturating_sub(stamp)
                        > crate::launch::HEARTBEAT_STALE_SECS
                })
                .unwrap_or(true);
            Some(PreviewPane {
                pane_id,
                tab_id: p.tab_id?,
                workspace_id: p.workspace_id.unwrap_or_default(),
                doc_token,
                pinned: p.tokens.contains_key(TOKEN_PINNED),
                control,
                stale,
                dedicated: p.tokens.contains_key(TOKEN_DEDICATED),
                origin_tab_id: p
                    .tokens
                    .get(TOKEN_ORIGIN_TAB)
                    .and_then(|value| value.as_str())
                    .unwrap_or_default()
                    .to_string(),
                resumed,
            })
        })
        .collect()
}

fn tab_is_plugin_only(pane_list_json: &str, tab_id: &str) -> bool {
    #[derive(serde::Deserialize)]
    struct Msg {
        result: Res,
    }
    #[derive(serde::Deserialize)]
    struct Res {
        #[serde(default)]
        panes: Vec<Pane>,
    }
    #[derive(serde::Deserialize)]
    struct Pane {
        tab_id: Option<String>,
        label: Option<String>,
        #[serde(default)]
        tokens: std::collections::BTreeMap<String, serde_json::Value>,
    }
    let Ok(msg) = serde_json::from_str::<Msg>(crate::launch::strip_bom(pane_list_json)) else {
        return false;
    };
    let panes: Vec<_> = msg
        .result
        .panes
        .into_iter()
        .filter(|pane| pane.tab_id.as_deref() == Some(tab_id))
        .collect();
    let resumed_preview = panes.iter().any(|pane| {
        pane.label
            .as_deref()
            .is_some_and(crate::launch::is_preview_label)
            && !pane.tokens.contains_key(METADATA_SOURCE)
    });
    !panes.is_empty()
        && panes.iter().all(|pane| {
            pane.tokens.contains_key(METADATA_SOURCE)
                || pane.tokens.contains_key("herdr-sidebar-explorer")
                || pane.tokens.contains_key("herdr-sidebar-git")
                || pane
                    .label
                    .as_deref()
                    .is_some_and(crate::launch::is_preview_label)
                || (resumed_preview
                    && matches!(
                        pane.label.as_deref(),
                        Some("Files" | "Sidebar" | "Explorer" | "Source Control")
                    ))
        })
}

/// The tab already showing `doc_key`, pinned or not — checked FIRST so
/// re-selecting an open file jumps instead of clobbering the ephemeral tab.
fn preview_for_doc(previews: &[PreviewPane], doc_key: &str) -> Option<PreviewPane> {
    let expected = document_token(doc_key);
    previews
        .iter()
        .find(|p| !p.stale && p.doc_token == expected)
        .cloned()
}

/// The ephemeral tab, if one exists. Pinned tabs are never overwritten.
fn reusable_preview(previews: &[PreviewPane]) -> Option<PreviewPane> {
    previews.iter().find(|p| !p.stale && !p.pinned).cloned()
}

/// An ephemeral preview's sidebar is itself a valid launch surface. Preserve
/// the tab that originally opened it rather than recording the preview tab as
/// its own return destination. A pinned preview is a normal caller tab.
fn preview_origin_tab(previews: &[PreviewPane], caller_tab_id: &str) -> String {
    previews
        .iter()
        .find(|preview| {
            !preview.stale
                && !preview.pinned
                && preview.tab_id == caller_tab_id
                && !preview.origin_tab_id.is_empty()
        })
        .map(|preview| preview.origin_tab_id.clone())
        .unwrap_or_else(|| caller_tab_id.to_string())
}

/// Split a viewer pane directly to the caller's right: split the right
/// NEIGHBOR and swap the fresh pane into its left slot (split only goes
/// right/down), so the layout reads sidebar | preview | rest.
fn spawn_viewer_pane(
    my_pane_id: &str,
    spawn_cwd: &Path,
    doc_key: &str,
    payload: &str,
) -> Result<(String, PathBuf), String> {
    let control = fresh_control_path();
    let doc_token = document_token(doc_key);
    let control_token = control_token(&control);
    write_scratch_file(&control, payload).map_err(|e| format!("preview failed: {e}"))?;
    let layout = ipc::call_text("pane.layout", serde_json::json!({ "pane_id": my_pane_id })).ok();
    let neighbor = layout
        .as_deref()
        .and_then(|json| right_neighbor(json, my_pane_id));
    // Splitting ourselves (no neighbor): a third of the tab, matching the
    // sidebar's usual share.
    let own_frac = 0.3;
    let (target, ratio, needs_swap) = match &neighbor {
        Some(id) => (id.clone(), 0.5, true),
        None => (my_pane_id.to_string(), own_frac, false),
    };
    let response = ipc::call_text(
        "pane.split",
        serde_json::json!({
            "target_pane_id": target,
            "direction": "right",
            "ratio": ratio,
            "focus": false,
            "cwd": spawn_cwd.display().to_string(),
            "env": preview_spawn_env(&control),
        }),
    );
    let new_pane = response
        .ok()
        .and_then(|r| crate::launch::split_pane_id(&r))
        .ok_or_else(|| {
            let _ = std::fs::remove_file(&control);
            "preview pane failed to open".to_string()
        })?;
    if needs_swap
        && !ipc::call_text(
            "pane.swap",
            serde_json::json!({ "source_pane_id": new_pane, "target_pane_id": target }),
        )
        .is_ok_and(|response| ipc_succeeded(&response))
    {
        cleanup_spawn(&new_pane, &control);
        return Err("preview pane could not be positioned".into());
    }
    if !ipc::call_text(
        "pane.report_metadata",
        serde_json::json!({
            "pane_id": new_pane,
            "source": METADATA_SOURCE,
            "tokens": {
                METADATA_SOURCE: crate::state::unix_now().to_string(),
                TOKEN_PATH: doc_token,
                TOKEN_CONTROL: control_token,
            },
        }),
    )
    .is_ok_and(|response| ipc_succeeded(&response))
    {
        cleanup_spawn(&new_pane, &control);
        return Err("preview pane could not be identified".into());
    }
    let _ = ipc::call_text(
        "pane.rename",
        serde_json::json!({ "pane_id": new_pane, "label": "Preview" }),
    );
    Ok((new_pane, control))
}

fn start_viewer_pane(pane_id: &str) -> bool {
    let command = format!("{} --preview", crate::state::EXECUTABLE_NAME);
    ipc::call_text(
        "pane.send_input",
        serde_json::json!({ "pane_id": pane_id, "text": command, "keys": ["Enter"] }),
    )
    .is_ok_and(|response| ipc_succeeded(&response))
}

fn mark_dedicated_preview(pane_id: &str) -> bool {
    ipc::call_text(
        "pane.report_metadata",
        serde_json::json!({
            "pane_id": pane_id,
            "source": METADATA_SOURCE,
            "tokens": { TOKEN_DEDICATED: "1" },
        }),
    )
    .is_ok_and(|response| ipc_succeeded(&response))
}

fn cleanup_spawn(pane_id: &str, control: &Path) {
    let _ = std::fs::remove_file(control);
    let _ = ipc::call_text("pane.close", serde_json::json!({ "pane_id": pane_id }));
}

fn cleanup_moved_spawn(pane_id: &str, tab_id: &str, control: &Path) {
    let _ = std::fs::remove_file(control);
    let plugin_only = ipc::call_text("pane.list", serde_json::json!({}))
        .ok()
        .is_some_and(|list| tab_is_plugin_only(&list, tab_id));
    if plugin_only {
        let _ = ipc::call_text("tab.close", serde_json::json!({ "tab_id": tab_id }));
    } else {
        let _ = ipc::call_text("pane.close", serde_json::json!({ "pane_id": pane_id }));
    }
}

fn pane_move_changed(response: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(crate::launch::strip_bom(response))
        .ok()
        .and_then(|value| {
            value
                .get("result")?
                .get("move_result")?
                .get("changed")?
                .as_bool()
        })
        .unwrap_or(false)
}

fn ipc_succeeded(response: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(crate::launch::strip_bom(response))
        .ok()
        .is_some_and(|value| value.get("result").is_some() && value.get("error").is_none())
}

fn preview_spawn_env(control: &Path) -> serde_json::Value {
    let mut env = crate::state::spawn_env();
    env[crate::state::PREVIEW_CONTROL_ENV] =
        serde_json::Value::String(control.display().to_string());
    env
}

/// The pane directly to the right of `pane_id` (sharing vertical overlap),
/// from a `pane.layout` response.
fn right_neighbor(layout_json: &str, pane_id: &str) -> Option<String> {
    #[derive(serde::Deserialize)]
    struct Msg {
        result: Res,
    }
    #[derive(serde::Deserialize)]
    struct Res {
        layout: L,
    }
    #[derive(serde::Deserialize)]
    struct L {
        #[serde(default)]
        panes: Vec<P>,
    }
    #[derive(serde::Deserialize)]
    struct P {
        pane_id: Option<String>,
        rect: Option<R>,
    }
    #[derive(serde::Deserialize)]
    struct R {
        x: i64,
        y: i64,
        width: i64,
        height: i64,
    }
    let msg: Msg = serde_json::from_str(layout_json.trim_start_matches('\u{feff}')).ok()?;
    let panes = &msg.result.layout.panes;
    let me = panes
        .iter()
        .find(|p| p.pane_id.as_deref() == Some(pane_id))?
        .rect
        .as_ref()?;
    let (my_right, my_top, my_bottom) = (me.x + me.width, me.y, me.y + me.height);
    panes
        .iter()
        .filter(|p| p.pane_id.as_deref() != Some(pane_id))
        .filter_map(|p| Some((p.pane_id.clone()?, p.rect.as_ref()?)))
        .find(|(_, r)| r.x == my_right && r.y < my_bottom && r.y + r.height > my_top)
        .map(|(id, _)| id)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc_of(lines: Vec<Line<'static>>, numbered: bool) -> Doc {
        Doc {
            name: "t".into(),
            context: String::new(),
            lines,
            numbered,
            scroll: 0,
            wrap: true,
            rows: Vec::new(),
            rows_key: None,
            pending_src: None,
            selection: PreviewSelection::default(),
        }
    }

    fn row_texts(rows: &[Row]) -> Vec<String> {
        rows.iter()
            .map(|r| r.line.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect()
    }

    #[test]
    fn wrapping_makes_every_continuation_row_scrollable() {
        // One source line, four rows' worth of text in a 10-wide pane.
        let long = "alpha beta gamma delta epsilon zeta";
        let mut doc = doc_of(vec![Line::raw(long), Line::raw("tail")], false);
        doc.relayout(10);
        assert!(doc.rows.len() > 2, "the long line must occupy several rows");
        // Every row belongs to a source line, in order, and the last row is
        // reachable by scrolling — which the pre-fix source-line scroll
        // (capped at lines.len() - 1 = 1) could never do.
        assert_eq!(doc.rows.last().map(|r| r.src), Some(1));
        assert_eq!(
            row_texts(&doc.rows).concat().replace(' ', ""),
            format!("{long}tail").replace(' ', "")
        );
        let max = doc.rows.len() - 1;
        assert!(max > 1);
    }

    #[test]
    fn wrap_off_keeps_one_row_per_source_line() {
        let mut doc = doc_of(vec![Line::raw("a".repeat(120)), Line::raw("b")], false);
        doc.wrap = false;
        doc.relayout(20);
        assert_eq!(doc.rows.len(), 2);
        assert_eq!(
            doc.rows.iter().map(|r| r.src).collect::<Vec<_>>(),
            vec![0, 1]
        );
    }

    #[test]
    fn the_gutter_is_blank_on_continuation_rows() {
        let mut doc = doc_of(
            vec![Line::raw("one two three four five six"), Line::raw("x")],
            true,
        );
        doc.relayout(14);
        let texts = row_texts(&doc.rows);
        assert!(texts[0].starts_with("1 "), "{texts:?}");
        // A continuation indents to the number column instead of renumbering.
        assert!(texts[1].starts_with("  "), "{texts:?}");
        assert_eq!(doc.rows[1].src, 0);
        // The next source line gets its own number.
        let second = doc.rows.iter().position(|r| r.src == 1).unwrap();
        assert!(texts[second].starts_with("2 "), "{texts:?}");
    }

    #[test]
    fn preview_selection_copies_text_without_line_numbers() {
        let mut doc = doc_of(vec![Line::raw("alpha beta"), Line::raw("gamma")], true);
        doc.relayout(40);
        doc.selection.anchor = Some(RenderPos { row: 0, col: 1 });
        doc.selection.cursor = Some(RenderPos { row: 1, col: 2 });
        assert_eq!(doc.selected_text().as_deref(), Some("lpha beta\nga"));
    }

    #[test]
    fn preview_selection_does_not_copy_visual_wrap_breaks() {
        let mut doc = doc_of(vec![Line::raw("alpha beta")], false);
        doc.relayout(6);
        assert_eq!(doc.rows.len(), 2);
        let last_col = row_text_without_gutter(doc.rows.last().unwrap(), 0)
            .chars()
            .count();
        doc.selection.anchor = Some(RenderPos::default());
        doc.selection.cursor = Some(RenderPos {
            row: 1,
            col: last_col,
        });
        assert_eq!(doc.selected_text().as_deref(), Some("alpha beta"));
    }

    #[test]
    fn unchanged_diff_refresh_preserves_selection_and_layout() {
        let mut doc = doc_of(vec![Line::raw("-old"), Line::raw("+new")], false);
        doc.relayout(40);
        doc.scroll = 1;
        doc.selection.anchor = Some(RenderPos { row: 0, col: 1 });
        doc.selection.cursor = Some(RenderPos { row: 1, col: 3 });
        let selection = doc.selection;
        let rows_key = doc.rows_key;

        let refreshed = doc_of(vec![Line::raw("-old"), Line::raw("+new")], false);
        apply_diff_refresh(&mut doc, refreshed);

        assert_eq!(doc.selection.anchor, selection.anchor);
        assert_eq!(doc.selection.cursor, selection.cursor);
        assert_eq!(doc.rows_key, rows_key);
        assert_eq!(doc.scroll, 1);
    }

    #[test]
    fn build_rows_expands_tabs_in_wrapped_and_unwrapped_modes() {
        let line = Line::raw("\t1234");
        let wrapped = build_rows(std::slice::from_ref(&line), false, true, 4);
        assert_eq!(wrapped.len(), 2);
        assert_eq!(wrapped[0].line.spans[0].content.as_ref(), "    ");
        let unwrapped = build_rows(&[line], false, false, 4);
        let text: String = unwrapped[0]
            .line
            .spans
            .iter()
            .map(|span| span.content.as_ref())
            .collect();
        assert_eq!(text, "    1234");
        assert!(!text.contains('\t'));
    }

    #[test]
    fn tinted_diff_rows_stay_tinted_across_the_wrap() {
        use ratatui::style::Stylize;
        let mut doc = doc_of(
            vec![Line::raw("+ a long added line of code here").on_green()],
            false,
        );
        doc.relayout(12);
        assert!(doc.rows.len() > 1);
        for row in &doc.rows {
            assert_eq!(row.line.style.bg, Some(Color::Green));
            // Padded to the pane edge so the tint is a full-width band.
            assert_eq!(row.line.width(), 12);
        }
    }

    #[test]
    fn toggling_wrap_holds_the_readers_place_by_source_line() {
        let lines: Vec<Line<'static>> = (0..6)
            .map(|n| Line::raw(format!("line {n} with a good deal of text on it")))
            .collect();
        let mut doc = doc_of(lines, false);
        doc.relayout(12);
        // Scroll to the first row of source line 3.
        doc.scroll = doc.rows.iter().position(|r| r.src == 3).unwrap();
        assert_eq!(doc.top_src(), 3);

        doc.pending_src = Some(doc.top_src());
        doc.wrap = false;
        doc.relayout(12);
        assert_eq!(doc.scroll, 3, "unwrapped rows are 1:1 with source lines");
        assert_eq!(doc.top_src(), 3);

        doc.pending_src = Some(doc.top_src());
        doc.wrap = true;
        doc.relayout(12);
        assert_eq!(doc.top_src(), 3, "and back, still on the same source line");
    }

    /// End-to-end through the real draw: the pane is 6 rows tall (1 header,
    /// 4 body, 1 footer) and the doc is a single line four rows long when
    /// wrapped. Scrolling must walk it row by row and reach the tail — the
    /// pre-fix source-line scroll had a max of 0 here, so everything past
    /// the first screen was unreachable.
    #[test]
    fn the_rendered_pane_scrolls_through_a_wrapped_line() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let words = "alpha bravo charlie delta echo foxtrot golf hotel india juliet";
        let mut doc = doc_of(vec![Line::raw(words)], false);
        let mut terminal = Terminal::new(TestBackend::new(16, 6)).unwrap();

        let render = |terminal: &mut Terminal<TestBackend>, doc: &mut Doc| -> Vec<String> {
            terminal
                .draw(|f| {
                    draw_doc(f, doc, IconTheme::Emoji, false, None);
                })
                .unwrap();
            terminal
                .backend()
                .buffer()
                .content()
                .chunks(16)
                .map(|row| row.iter().map(|c| c.symbol()).collect::<String>())
                .collect()
        };

        let first = render(&mut terminal, &mut doc);
        assert!(doc.rows.len() > 4, "16 cols must need more than one screen");
        // Body rows are 1..5; the header and footer are chrome.
        assert!(first[1].starts_with("alpha"), "{first:?}");

        // Walk to the bottom the way the key handler does.
        let max = doc.rows.len() - 1;
        doc.scroll = max;
        let last = render(&mut terminal, &mut doc);
        let body: String = last[1..5].concat();
        assert!(
            body.contains("juliet"),
            "the final row must be reachable: {last:?}"
        );

        // …and the clamp keeps a full screen of content in view rather than
        // scrolling off into blank rows.
        assert!(doc.scroll <= doc.rows.len().saturating_sub(4));
    }

    /// With wrapping off the same doc is one clipped row, and the toggle
    /// round-trips without losing the reader's place.
    #[test]
    fn the_rendered_pane_clips_when_wrapping_is_off() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let words = "alpha bravo charlie delta echo foxtrot golf hotel india juliet";
        let mut doc = doc_of(vec![Line::raw(words)], false);
        doc.wrap = false;
        let mut terminal = Terminal::new(TestBackend::new(16, 6)).unwrap();
        terminal
            .draw(|f| {
                draw_doc(f, &mut doc, IconTheme::Emoji, false, None);
            })
            .unwrap();
        assert_eq!(doc.rows.len(), 1);
        let rendered: String = terminal
            .backend()
            .buffer()
            .content()
            .chunks(16)
            .map(|row| row.iter().map(|c| c.symbol()).collect::<String>())
            .collect::<Vec<_>>()[1]
            .clone();
        assert!(rendered.starts_with("alpha bravo char"), "{rendered:?}");
        assert!(!rendered.contains("juliet"));
    }

    #[test]
    fn a_resize_relayouts_and_keeps_the_rows_cached_otherwise() {
        let mut doc = doc_of(
            vec![Line::raw("wrap me around a narrow pane please")],
            false,
        );
        doc.relayout(10);
        let narrow = doc.rows.len();
        doc.relayout(10);
        assert_eq!(doc.rows.len(), narrow, "same key: no rebuild, no change");
        doc.relayout(40);
        assert!(doc.rows.len() < narrow, "a wider pane needs fewer rows");
    }

    /// One pinned preview, one ephemeral preview, and a sidebar pane that is
    /// neither — the three cases every routing decision must separate.
    const PREVIEWS: &str = r#"{"result":{"panes":[
        {"pane_id":"w4:p1","tab_id":"w4:t1","tokens":{"herdr-sidebar-explorer":"1"}},
        {"pane_id":"w4:p2","tab_id":"w4:t2",
          "tokens":{"herdr-sidebar-preview":"9999999999","hs-preview-path":"/r/a.rs","hs-preview-pinned":"1","hs-preview-dedicated":"1","hs-preview-origin-tab":"w4:t1","hs-preview-control":"C:/state/a preview.ctl"}},
        {"pane_id":"w4:p3","tab_id":"w4:t3",
          "tokens":{"herdr-sidebar-preview":"9999999999","hs-preview-path":"/r/b.rs"}}
    ]}}"#;

    #[test]
    fn a_pinned_tab_is_no_longer_reusable() {
        let before = r#"{"result":{"panes":[
            {"pane_id":"w4:p3","tab_id":"w4:t3","tokens":{"herdr-sidebar-preview":"9999999999","hs-preview-path":"/r/b.rs"}}
        ]}}"#;
        let after = r#"{"result":{"panes":[
            {"pane_id":"w4:p3","tab_id":"w4:t3",
             "tokens":{"herdr-sidebar-preview":"9999999999","hs-preview-path":"/r/b.rs","hs-preview-pinned":"1"}}
        ]}}"#;
        assert!(reusable_preview(&previews_in(before)).is_some());
        assert!(
            reusable_preview(&previews_in(after)).is_none(),
            "pinning must push the next file onto a new tab"
        );
        // ...and the pinned tab is still reachable by its document.
        assert!(preview_for_doc(&previews_in(after), "/r/b.rs").is_some());
    }

    #[test]
    fn legacy_control_files_are_addressed_by_the_preview_pane() {
        assert_eq!(
            control_path_for_pane("w4:p9"),
            control_path_for_pane("w4:p9")
        );
        assert_ne!(
            control_path_for_pane("w4:p9"),
            control_path_for_pane("w4:pA")
        );
        assert!(
            control_path_for_pane("w4:p9")
                .to_string_lossy()
                .contains("w4_p9"),
            "colons are not filename-safe"
        );
    }

    #[test]
    fn preview_control_path_travels_in_the_spawn_environment() {
        let control = Path::new("C:/plugin state/preview control.ctl");
        let env = preview_spawn_env(control);
        assert_eq!(
            env.get(crate::state::PREVIEW_CONTROL_ENV)
                .and_then(|value| value.as_str()),
            Some("C:/plugin state/preview control.ctl")
        );
        assert!(env.get("PATH").and_then(|value| value.as_str()).is_some());
    }

    #[test]
    fn metadata_uses_compact_tokens_that_survive_host_limits() {
        let control = fresh_control_path();
        let token = control_token(&control);
        assert!(token.len() < 64, "{token}");
        assert_eq!(control_from_token(&token), control);
        assert_eq!(document_token(&"x".repeat(500)).len(), 16);
    }

    #[test]
    fn whole_tab_close_requires_only_plugin_owned_panes() {
        let plugin_only = r#"{"result":{"panes":[
            {"tab_id":"w1:t2","label":"Sidebar","tokens":{"herdr-sidebar-explorer":"1"}},
            {"tab_id":"w1:t2","label":"a.rs · preview","tokens":{"herdr-sidebar-preview":"1"}}
        ]}}"#;
        let with_shell = r#"{"result":{"panes":[
            {"tab_id":"w1:t2","label":"Sidebar","tokens":{"herdr-sidebar-explorer":"1"}},
            {"tab_id":"w1:t2","label":"a.rs · preview","tokens":{"herdr-sidebar-preview":"1"}},
            {"tab_id":"w1:t2","label":"shell","tokens":{}}
        ]}}"#;
        let resumed = r#"{"result":{"panes":[
            {"tab_id":"w1:t2","label":"Sidebar","tokens":{}},
            {"tab_id":"w1:t2","label":"a.rs · editor","tokens":{}}
        ]}}"#;
        let resumed_with_shell = r#"{"result":{"panes":[
            {"tab_id":"w1:t2","label":"Sidebar","tokens":{}},
            {"tab_id":"w1:t2","label":"a.rs · preview","tokens":{}},
            {"tab_id":"w1:t2","label":"pwsh","tokens":{}}
        ]}}"#;
        assert!(tab_is_plugin_only(plugin_only, "w1:t2"));
        assert!(!tab_is_plugin_only(with_shell, "w1:t2"));
        assert!(tab_is_plugin_only(resumed, "w1:t2"));
        assert!(!tab_is_plugin_only(resumed_with_shell, "w1:t2"));
        assert!(!tab_is_plugin_only(plugin_only, "w1:t9"));
    }

    /// The ephemeral tab is per WORKSPACE. Session-wide, opening a file in
    /// tremor found learnings' unpinned preview, rewrote it, and focus jumped
    /// to the other project — the tree "stayed" on learnings because you were
    /// teleported there.
    #[test]
    fn the_ephemeral_tab_is_not_shared_between_workspaces() {
        let json = r#"{"result":{"panes":[
            {"pane_id":"wB:pE","tab_id":"wB:t3","workspace_id":"wB",
             "tokens":{"herdr-sidebar-preview":"9999999999","hs-preview-path":"/learnings/a.md"}},
            {"pane_id":"wH:p9","tab_id":"wH:t4","workspace_id":"wH",
             "tokens":{"herdr-sidebar-preview":"9999999999","hs-preview-path":"/tremor/b.rs","hs-preview-pinned":"1"}}
        ]}}"#;
        let all = previews_in(json);
        assert_eq!(all.len(), 2);

        let tremor: Vec<_> = all
            .iter()
            .filter(|p| p.workspace_id == "wH")
            .cloned()
            .collect();
        assert!(
            reusable_preview(&tremor).is_none(),
            "learnings' ephemeral tab must not be reusable from tremor"
        );
        let learnings: Vec<_> = all
            .iter()
            .filter(|p| p.workspace_id == "wB")
            .cloned()
            .collect();
        assert_eq!(reusable_preview(&learnings).unwrap().pane_id, "wB:pE");

        // Matching an already-open document is scoped too: jumping to another
        // workspace's tab is the same teleport by a different route.
        assert!(preview_for_doc(&tremor, "/learnings/a.md").is_none());
    }

    #[test]
    fn previews_carry_their_document_and_pin_state() {
        let ps = previews_in(PREVIEWS);
        assert_eq!(ps.len(), 2, "sidebar panes are not preview candidates");
        let a = ps
            .iter()
            .find(|p| p.doc_token == document_token("/r/a.rs"))
            .unwrap();
        assert!(a.pinned);
        assert!(a.dedicated);
        assert!(!a.resumed);
        assert_eq!(a.tab_id, "w4:t2");
        assert_eq!(a.origin_tab_id, "w4:t1");
        assert_eq!(a.control, PathBuf::from("C:/state/a preview.ctl"));
        assert!(
            !ps.iter()
                .find(|p| p.doc_token == document_token("/r/b.rs"))
                .unwrap()
                .pinned
        );
    }

    #[test]
    fn an_open_document_is_matched_before_anything_is_reused() {
        let ps = previews_in(PREVIEWS);
        assert_eq!(preview_for_doc(&ps, "/r/a.rs").unwrap().tab_id, "w4:t2");
        assert!(preview_for_doc(&ps, "/r/zz.rs").is_none());
    }

    #[test]
    fn only_unpinned_previews_are_reusable() {
        let ps = previews_in(PREVIEWS);
        assert_eq!(
            reusable_preview(&ps).unwrap().doc_token,
            document_token("/r/b.rs")
        );

        let all_pinned = r#"{"result":{"panes":[
            {"pane_id":"w4:p2","tab_id":"w4:t2",
             "tokens":{"herdr-sidebar-preview":"9999999999","hs-preview-path":"/r/a.rs","hs-preview-pinned":"1"}}
        ]}}"#;
        assert!(
            reusable_preview(&previews_in(all_pinned)).is_none(),
            "every tab pinned must force a new tab"
        );
    }

    #[test]
    fn ephemeral_previews_preserve_the_original_return_tab() {
        let mut previews = previews_in(PREVIEWS);
        let ephemeral = previews.iter_mut().find(|preview| !preview.pinned).unwrap();
        ephemeral.origin_tab_id = "w4:t1".into();
        assert_eq!(preview_origin_tab(&previews, "w4:t3"), "w4:t1");
        assert_eq!(preview_origin_tab(&previews, "w4:t2"), "w4:t2");
        assert_eq!(preview_origin_tab(&previews, "w4:t9"), "w4:t9");
    }

    #[test]
    fn pinning_requires_the_viewer_to_acknowledge_that_document() {
        let previews = previews_in(PREVIEWS);
        let target = PreviewTarget {
            pane_id: "w4:p3".into(),
            tab_id: "w4:t3".into(),
            origin_tab_id: "w4:t1".into(),
        };
        assert!(target_is_showing(&previews, &target, "/r/b.rs"));
        assert!(!target_is_showing(&previews, &target, "/r/other.rs"));
    }

    #[test]
    fn a_nul_after_the_old_probe_window_is_still_binary() {
        let path = std::env::temp_dir().join(format!("viewer-late-nul-{}", std::process::id()));
        let mut bytes = vec![b'a'; 9000];
        bytes.push(0);
        std::fs::write(&path, bytes).unwrap();
        let doc = load_file(&path);
        let rendered: String = doc.lines[0]
            .spans
            .iter()
            .map(|span| span.content.as_ref())
            .collect();
        assert!(rendered.contains("binary file"), "{rendered}");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn stale_preview_heartbeats_are_neither_matched_nor_reused() {
        let stale = r#"{"result":{"panes":[{
            "pane_id":"w4:p3","tab_id":"w4:t3","workspace_id":"w4",
            "tokens":{"herdr-sidebar-preview":"1","hs-preview-path":"/r/b.rs"}
        }]}}"#;
        let previews = previews_in(stale);
        assert!(previews[0].stale);
        assert!(preview_for_doc(&previews, "/r/b.rs").is_none());
        assert!(reusable_preview(&previews).is_none());
    }

    #[test]
    fn label_only_resumed_previews_are_stale_cleanup_candidates() {
        let resumed = r#"{"result":{"panes":[{
            "pane_id":"w4:p3","tab_id":"w4:t3","workspace_id":"w4",
            "label":"b.rs · preview","tokens":{}
        }]}}"#;
        let previews = previews_in(resumed);
        assert_eq!(previews.len(), 1);
        assert!(previews[0].stale);
        assert!(previews[0].resumed);
        assert!(previews[0].doc_token.is_empty());
        assert!(preview_for_doc(&previews, "/r/b.rs").is_none());
        assert!(reusable_preview(&previews).is_none());
    }

    #[test]
    fn document_metadata_without_a_heartbeat_is_stale() {
        let missing_heartbeat = r#"{"result":{"panes":[{
            "pane_id":"w4:p3","tab_id":"w4:t3","workspace_id":"w4",
            "label":"b.rs · preview","tokens":{"hs-preview-path":"/r/b.rs"}
        }]}}"#;
        let previews = previews_in(missing_heartbeat);
        assert_eq!(previews.len(), 1);
        assert!(previews[0].stale);
        assert!(previews[0].resumed);
    }

    #[test]
    fn doc_keys_separate_a_file_from_its_diff_and_its_history() {
        let f = doc_key_for_file(Path::new("/repo/src/main.rs"));
        let d = doc_key_for_diff(Path::new("/repo"), "src/main.rs", "staged");
        let w = doc_key_for_diff(Path::new("/repo"), "src/main.rs", "worktree");
        let s = doc_key_for_show(Path::new("/repo"), "HEAD~1", Some("src/main.rs"));
        assert_eq!(f, "/repo/src/main.rs");
        assert_ne!(f, d, "a file and its diff need their own tabs");
        assert_ne!(d, w, "staged and worktree diffs are different documents");
        assert_ne!(d, s, "a diff and a git-show are different documents");
        assert!(d.starts_with("diff:"), "{d}");
        assert!(s.starts_with("show:"), "{s}");
    }

    #[test]
    fn tab_labels_mark_the_ephemeral_tab_not_the_pinned_one() {
        // `*` warns "this one is about to be overwritten".
        assert_eq!(tab_label("/repo/src/main.rs", false), "main.rs · preview");
        assert_eq!(tab_label("/repo/src/main.rs", true), "main.rs");
        assert_eq!(
            parse_tab_label("main.rs · preview"),
            ("main.rs".to_string(), false)
        );
        assert_eq!(parse_tab_label("main.rs"), ("main.rs".to_string(), true));
        assert_eq!(
            tab_label("diff:/repo/src/main.rs:staged", false),
            "main.rs · preview"
        );
        assert_eq!(tab_label("show:/repo:abc123", true), "abc123");
        assert_eq!(tab_label("show:/repo:abc123:src/lib.rs", true), "lib.rs");
        assert_eq!(preview_pane_label("main.rs"), "main.rs · preview");
        assert_eq!(editor_pane_label("main.rs"), "main.rs · editor");
    }

    #[test]
    fn pane_move_requires_a_changed_success_result() {
        let moved = r#"{"result":{"type":"pane_move","move_result":{"changed":true}}}"#;
        let refused = r#"{"result":{"type":"pane_move","move_result":{"changed":false}}}"#;
        assert!(pane_move_changed(moved));
        assert!(!pane_move_changed(refused));
        assert!(!pane_move_changed(r#"{"error":{"message":"nope"}}"#));
    }

    #[cfg(unix)]
    #[test]
    fn scratch_dir_is_private_to_the_owning_user() {
        use std::os::unix::fs::PermissionsExt;
        let dir = scratch_dir();
        let mode = std::fs::metadata(&dir).unwrap().permissions().mode();
        assert_eq!(
            mode & 0o777,
            0o700,
            "scratch dir must not be group/world readable or writable"
        );
    }

    #[cfg(unix)]
    #[test]
    fn write_scratch_file_refuses_to_follow_a_preexisting_symlink() {
        use std::os::unix::fs::symlink;
        let dir = scratch_dir();
        let victim = dir.join(format!("aa-victim-{}.txt", std::process::id()));
        let link = dir.join(format!("aa-link-{}.ctl", std::process::id()));
        std::fs::write(&victim, "original victim contents").unwrap();
        let _ = std::fs::remove_file(&link);
        symlink(&victim, &link).unwrap();

        write_scratch_file(&link, "payload").unwrap();

        // The symlink must have been replaced by a real file, and the
        // victim it used to point at must be untouched.
        assert!(
            !std::fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(std::fs::read_to_string(&link).unwrap(), "payload");
        assert_eq!(
            std::fs::read_to_string(&victim).unwrap(),
            "original victim contents"
        );

        let _ = std::fs::remove_file(&victim);
        let _ = std::fs::remove_file(&link);
    }

    #[test]
    fn requests_roundtrip() {
        assert_eq!(parse_request("close"), Some(Request::Close));
        let f = file_request(Path::new("C:/x/y.rs"));
        assert_eq!(
            parse_request(&f),
            Some(Request::File(PathBuf::from("C:/x/y.rs")))
        );
        let s = show_request(Path::new("C:/repo"), "stash@{1}", None);
        assert_eq!(
            parse_request(&s),
            Some(Request::Show {
                root: PathBuf::from("C:/repo"),
                spec: "stash@{1}".into(),
                path: None,
            })
        );
        let s = show_request(Path::new("C:/repo"), "a1b2c3d", Some("src/a.rs"));
        assert_eq!(
            parse_request(&s),
            Some(Request::Show {
                root: PathBuf::from("C:/repo"),
                spec: "a1b2c3d".into(),
                path: Some("src/a.rs".into()),
            })
        );
        let d = diff_request(Path::new("C:/repo"), "src/a.rs", "staged");
        assert_eq!(
            parse_request(&d),
            Some(Request::Diff {
                root: PathBuf::from("C:/repo"),
                rel: "src/a.rs".into(),
                kind: "staged".into()
            })
        );
        // Legacy bare path still works.
        assert_eq!(
            parse_request("C:/plain.txt"),
            Some(Request::File(PathBuf::from("C:/plain.txt")))
        );
        assert_eq!(parse_request("  "), None);
    }

    #[test]
    fn glow_markdown_returns_styled_spans() {
        // Skip if glow is not installed
        if std::process::Command::new("glow")
            .arg("--version")
            .output()
            .is_err()
        {
            return;
        }
        let md = "# Heading\n\n**bold** and `code`\n";
        let lines = glow_markdown(md, 80);
        assert!(lines.is_some(), "glow_markdown returned None");
        let lines = lines.unwrap();
        assert!(!lines.is_empty(), "glow_markdown returned empty lines");
        // At least one span must have a non-default style (proof that ANSI was parsed)
        let has_styled = lines.iter().any(|l| {
            l.spans
                .iter()
                .any(|s| s.style != ratatui::style::Style::default())
        });
        assert!(
            has_styled,
            "glow_markdown returned no styled spans — ANSI not parsed"
        );
    }

    #[test]
    fn viewer_lookup_reports_staleness() {
        let now = crate::state::unix_now();
        let json = format!(
            r#"{{"result":{{"panes":[
                {{"pane_id":"w1:p1","tab_id":"w1:t1"}},
                {{"pane_id":"w1:p2","tab_id":"w1:t1","tokens":{{"herdr-sidebar-preview":"{}"}}}}
            ]}}}}"#,
            now - 2
        );
        assert_eq!(
            viewer_pane_in_tab(&json, "w1:p1"),
            Some(("w1:p2".into(), false))
        );
        let stale = format!(
            r#"{{"result":{{"panes":[
                {{"pane_id":"w1:p1","tab_id":"w1:t1"}},
                {{"pane_id":"w1:p2","tab_id":"w1:t1","tokens":{{"herdr-sidebar-preview":"{}"}}}}
            ]}}}}"#,
            now - 999
        );
        assert_eq!(
            viewer_pane_in_tab(&stale, "w1:p1"),
            Some(("w1:p2".into(), true))
        );

        let resumed = r#"{"result":{"panes":[
            {"pane_id":"w1:p1","tab_id":"w1:t1"},
            {"pane_id":"w1:p2","tab_id":"w1:t1","label":"Preview · routes.rs"}
        ]}}"#;
        assert_eq!(
            viewer_pane_in_tab(resumed, "w1:p1"),
            Some(("w1:p2".into(), true)),
            "document-labelled resumed viewers remain reclaimable"
        );
    }
}
