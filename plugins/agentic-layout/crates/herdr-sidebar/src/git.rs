//! Git plumbing: repo discovery, `status --porcelain -z` parsing, and the
//! stage / unstage / commit operations, all via the `git` CLI (no libgit2).
//! Parsing is pure and unit-tested; commands run with the repo toplevel as cwd
//! so the repo-relative paths porcelain reports resolve even when the pane's
//! cwd is a subdirectory.

use std::path::{Path, PathBuf};
use std::process::Command;

/// One file in the staged or unstaged list.
#[derive(Clone, Debug, PartialEq)]
pub struct FileEntry {
    /// Repo-relative path (the new path, for renames), `/`-separated as git reports it.
    pub path: String,
    /// Rename/copy source, when there is one — unstaging a rename must reset both.
    pub orig: Option<String>,
    /// The VS Code-style status letter to display: M, A, D, R, C, U (untracked),
    /// or `!` for merge conflicts.
    pub letter: char,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Status {
    pub branch: String,
    pub staged: Vec<FileEntry>,
    pub unstaged: Vec<FileEntry>,
    /// Commits ahead of / behind the upstream, from the porcelain `##` header.
    pub ahead: usize,
    pub behind: usize,
    /// The branch has an upstream at all (the header carries `...remote`).
    pub has_upstream: bool,
}

#[derive(Clone)]
pub struct Git {
    root: PathBuf,
}

/// What one [`Git::stage_under`] call did: how many paths it staged, and how
/// many it deliberately left alone because they live at or inside a NESTED
/// repository. The second number is what lets the UI explain a stage that
/// looks like it did nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Staged {
    pub count: usize,
    pub skipped_nested: usize,
}

impl Git {
    /// Locate the repository containing `dir`; Err with git's message when there
    /// is none (or git itself is missing).
    pub fn discover(dir: &Path) -> Result<Git, String> {
        let out = run_in(dir, &["rev-parse", "--show-toplevel"])?;
        let root = out.trim();
        if root.is_empty() {
            return Err("not inside a git repository".to_string());
        }
        Ok(Git {
            root: PathBuf::from(root),
        })
    }

    /// All repositories visible from `dir`, VS Code style: the repository
    /// containing `dir` (if any) plus child repositories up to two directory
    /// levels down (a `.git` dir, or a `.git` FILE — worktrees/submodules).
    /// Deduped by root; the containing repo sorts first, children by path.
    pub fn discover_all(dir: &Path) -> Vec<Git> {
        let mut repos: Vec<Git> = Vec::new();
        let mut push = |git: Git| {
            if !repos.iter().any(|r| r.root == git.root) {
                repos.push(git);
            }
        };
        if let Ok(git) = Git::discover(dir) {
            push(git);
        }
        for child in child_dirs(dir, 2) {
            if child.join(".git").exists()
                && let Ok(git) = Git::discover(&child)
            {
                push(git);
            }
        }
        repos
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Display name for repo headers: the root directory's name.
    pub fn name(&self) -> String {
        self.root
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| self.root.display().to_string())
    }

    /// VS Code's Sync Changes: pull (rebase, autostash) then push. Returns a
    /// short human summary; the caller runs this on a background thread.
    pub fn sync(&self) -> Result<String, String> {
        run_in(&self.root, &["pull", "--rebase", "--autostash"])?;
        run_in(&self.root, &["push"])?;
        Ok("synced with remote".to_string())
    }

    pub fn status(&self) -> Result<Status, String> {
        let out = run_in(
            &self.root,
            &[
                "status",
                "--porcelain",
                "-z",
                "--branch",
                "--renames",
                "--untracked-files=all",
            ],
        )?;
        Ok(parse_status(&out))
    }

    /// Stage one entry: `add -A` records modifications, additions, and deletions alike.
    pub fn stage(&self, entry: &FileEntry) -> Result<(), String> {
        let mut args = vec!["add", "-A", "--", entry.path.as_str()];
        if let Some(original) = entry.orig.as_deref() {
            args.push(original);
        }
        run_in(&self.root, &args).map(drop)
    }

    pub fn stage_all(&self) -> Result<(), String> {
        run_in(&self.root, &["add", "-A"]).map(drop)
    }

    /// Whether HEAD resolves to a real commit — false only on an unborn
    /// branch (a repo with no commits yet), where `git reset` has nothing to
    /// reset against.
    fn has_head(&self) -> bool {
        run_in(&self.root, &["rev-parse", "--verify", "HEAD"]).is_ok()
    }

    /// Unstage one entry. `reset` needs a HEAD to reset against; on an unborn
    /// branch (no commits yet) fall back to dropping the path from the index.
    /// The fallback is destructive on a repo WITH a HEAD (`rm --cached` stages
    /// a deletion instead of unstaging), so it only runs for the unborn-branch
    /// case — any other `reset` failure is propagated instead of swallowed.
    pub fn unstage(&self, entry: &FileEntry) -> Result<(), String> {
        let mut args = vec!["reset", "-q", "--", entry.path.as_str()];
        if let Some(orig) = &entry.orig {
            args.push(orig);
        }
        match run_in(&self.root, &args) {
            Ok(_) => Ok(()),
            Err(e) if self.has_head() => Err(e),
            Err(_) => run_in(
                &self.root,
                &["rm", "--cached", "-r", "-q", "--", &entry.path],
            )
            .map(drop),
        }
    }

    pub fn unstage_all(&self) -> Result<(), String> {
        match run_in(&self.root, &["reset", "-q"]) {
            Ok(_) => Ok(()),
            Err(e) if self.has_head() => Err(e),
            Err(_) => run_in(&self.root, &["rm", "--cached", "-r", "-q", "--", "."]).map(drop),
        }
    }

    /// Commit the staged changes; returns git's summary line ("[branch abc1234] …").
    pub fn commit(&self, message: &str) -> Result<String, String> {
        let out = run_in(&self.root, &["commit", "-m", message])?;
        Ok(out.lines().next().unwrap_or("committed").to_string())
    }

    /// Throw away a file's working-tree changes: untracked files are deleted,
    /// tracked ones restored from HEAD (the caller confirms first).
    pub fn discard(&self, entry: &FileEntry) -> Result<(), String> {
        if entry.letter == 'U' {
            return run_in(&self.root, &["clean", "-fd", "--", &entry.path]).map(drop);
        }
        run_in(&self.root, &["checkout", "--", &entry.path]).map(drop)
    }

    /// The diff a commit-message suggestion should describe: the staged diff
    /// when something is staged (that is what would be committed), else the
    /// working-tree diff. Untracked files only appear as names, so they ride
    /// along in the returned path list either way.
    pub fn diff_for_message(&self) -> Result<(String, Vec<String>), String> {
        let staged = run_in(&self.root, &["diff", "--cached", "--stat", "--patch"])?;
        let (diff, names_args): (String, &[&str]) = if staged.trim().is_empty() {
            let unstaged = run_in(&self.root, &["diff", "--stat", "--patch"])?;
            (unstaged, &["diff", "--name-only"])
        } else {
            (staged, &["diff", "--cached", "--name-only"])
        };
        let mut files: Vec<String> = run_in(&self.root, names_args)?
            .lines()
            .map(str::to_string)
            .filter(|l| !l.is_empty())
            .collect();
        if files.is_empty() {
            // Nothing tracked changed: describe the untracked files instead.
            files = run_in(&self.root, &["ls-files", "--others", "--exclude-standard"])?
                .lines()
                .map(str::to_string)
                .filter(|l| !l.is_empty())
                .collect();
        }
        Ok((diff, files))
    }

    /// Repo-relative roots of ignored paths, for the Explorer's `Ignored`
    /// decoration (issue #19). Deliberately a SECOND status call with
    /// `--untracked-files=normal`: `--ignored` combined with the `-uall` the
    /// main [`Git::status`] call uses expands every file inside `target/` and
    /// `node_modules/`, while `normal` keeps ignored directories collapsed to
    /// a single `dir/` entry — one cheap line instead of tens of thousands.
    pub fn ignored(&self) -> Result<Vec<String>, String> {
        let out = run_in(
            &self.root,
            &[
                "status",
                "--porcelain",
                "-z",
                "--ignored=traditional",
                "--untracked-files=normal",
            ],
        )?;
        Ok(parse_ignored(&out))
    }

    /// The repository that OWNS `path`: the NEAREST enclosing repo, found by
    /// git's own upward walk. A path inside a nested repository therefore
    /// belongs to the nested repo, never to the parent — the boundary rule
    /// issue #20 asks for.
    pub fn owner_of(path: &Path) -> Result<Git, String> {
        let dir = if path.is_dir() {
            path
        } else {
            path.parent().unwrap_or(path)
        };
        Git::discover(dir)
    }

    /// Stage everything under `target` that belongs to THIS repository —
    /// additions, modifications and deletions alike.
    ///
    /// Rather than handing git the directory (`git add -A -- dir`), the paths
    /// come from this repo's own `status`, filtered to the target subtree and
    /// then stripped of anything at or inside a NESTED repository root. A bare
    /// `git add` on a directory holding an unregistered inner repo records it
    /// as a gitlink ("adding embedded git repository"); enumerating instead
    /// makes the boundary explicit, and a nested repo's changes can only ever
    /// be staged by selecting something inside it (which `owner_of` then
    /// routes to the nested repo).
    pub fn stage_under(&self, target: &Path) -> Result<Staged, String> {
        let prefix = self.rel_of(target)?;
        let status = self.status()?;
        let candidates = paths_under(&status, prefix.as_deref());
        let before = candidates.len();
        let nested = self.nested_roots_for(&candidates);
        let paths = drop_nested(candidates, &nested);
        let skipped_nested = before - paths.len();
        if paths.is_empty() {
            return Ok(Staged {
                count: 0,
                skipped_nested,
            });
        }
        // Windows caps a command line at ~32k: stage in batches so a huge
        // untracked tree does not blow past it.
        for chunk in paths.chunks(64) {
            let mut args = vec!["add", "-A", "--"];
            args.extend(chunk.iter().map(String::as_str));
            run_in(&self.root, &args)?;
        }
        Ok(Staged {
            count: paths.len(),
            skipped_nested,
        })
    }

    /// `target` as a `/`-separated repo-relative path; `None` when it IS the
    /// repo root (no prefix = the whole repo). Refuse an outside or
    /// differently-normalized path rather than accidentally staging the whole
    /// repository.
    fn rel_of(&self, target: &Path) -> Result<Option<String>, String> {
        let rel = target.strip_prefix(&self.root).map_err(|_| {
            format!(
                "{} is outside repository {}",
                target.display(),
                self.root.display()
            )
        })?;
        let joined = rel
            .components()
            .map(|c| c.as_os_str().to_string_lossy().into_owned())
            .collect::<Vec<_>>()
            .join("/");
        Ok((!joined.is_empty()).then_some(joined))
    }

    /// The nested-repository roots that lie on the way to any of `paths`:
    /// every ancestor prefix (and the path itself) that carries its own
    /// `.git`, excluding this repo's root.
    fn nested_roots_for(&self, paths: &[String]) -> Vec<String> {
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut roots: Vec<String> = Vec::new();
        for path in paths {
            let parts: Vec<&str> = path.trim_end_matches('/').split('/').collect();
            for end in 1..=parts.len() {
                let prefix = parts[..end].join("/");
                if !seen.insert(prefix.clone()) {
                    continue;
                }
                let mut abs = self.root.clone();
                for part in &parts[..end] {
                    abs.push(part);
                }
                if abs.join(".git").exists() {
                    roots.push(prefix);
                }
            }
        }
        roots
    }

    // ---- Drawer queries (display-only lists, VS Code Git-Graph style) ----

    pub fn graph(&self, limit: usize) -> Result<Vec<String>, String> {
        let n = format!("-{limit}");
        lines(run_in(
            &self.root,
            &["log", "--graph", "--oneline", "--decorate=short", &n],
        )?)
    }

    pub fn commits(&self, limit: usize) -> Result<Vec<String>, String> {
        let n = format!("-{limit}");
        lines(run_in(
            &self.root,
            &["log", "--oneline", "--decorate=short", "--date=short", &n],
        )?)
    }

    pub fn file_history(&self, path: &str, limit: usize) -> Result<Vec<String>, String> {
        let n = format!("-{limit}");
        lines(run_in(
            &self.root,
            &["log", "--oneline", "--follow", &n, "--", path],
        )?)
    }

    /// Local + remote branches, the current one first and starred.
    pub fn branches(&self) -> Result<Vec<String>, String> {
        lines(run_in(
            &self.root,
            &[
                "branch",
                "-a",
                "--sort=-committerdate",
                "--format=%(HEAD) %(refname:short)",
            ],
        )?)
    }

    pub fn remotes(&self) -> Result<Vec<String>, String> {
        let out = run_in(&self.root, &["remote", "-v"])?;
        // `remote -v` lists fetch and push separately; one line per remote reads better.
        let mut seen = Vec::new();
        for line in out.lines() {
            if let Some(rest) = line.strip_suffix(" (fetch)") {
                seen.push(rest.replace('\t', "  "));
            }
        }
        Ok(seen)
    }

    pub fn stashes(&self) -> Result<Vec<String>, String> {
        lines(run_in(&self.root, &["stash", "list"])?)
    }

    pub fn tags(&self) -> Result<Vec<String>, String> {
        lines(run_in(&self.root, &["tag", "--sort=-creatordate"])?)
    }

    /// One line per worktree (`git worktree list`): path, short head,
    /// [branch] — the primary checkout first.
    pub fn worktrees(&self) -> Result<Vec<String>, String> {
        lines(run_in(&self.root, &["worktree", "list"])?)
    }

    /// Run an arbitrary git command in this repo — the escape hatch the
    /// drawer context menus use (checkout / merge / cherry-pick / …).
    pub fn raw(&self, args: &[&str]) -> Result<String, String> {
        run_in(&self.root, args)
    }
}

fn lines(out: String) -> Result<Vec<String>, String> {
    Ok(out
        .lines()
        .map(str::to_string)
        .filter(|l| !l.is_empty())
        .collect())
}

fn run_in(dir: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .arg("-c")
        .arg("color.ui=false")
        .args(args)
        .current_dir(dir)
        .output()
        .map_err(|e| format!("git: {e}"))?;
    if out.status.success() {
        return Ok(String::from_utf8_lossy(&out.stdout).into_owned());
    }
    let stderr = String::from_utf8_lossy(&out.stderr);
    Err(stderr
        .lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("git failed")
        .trim()
        .to_string())
}

/// Parse `git status --porcelain -z --branch` output. Entries are NUL-separated
/// `XY path`; a rename/copy is followed by a second NUL-separated field holding
/// the source path. X is the index (staged) state, Y the worktree state.
pub fn parse_status(raw: &str) -> Status {
    let mut status = Status::default();
    let mut parts = raw.split('\0');
    while let Some(entry) = parts.next() {
        if entry.is_empty() {
            continue;
        }
        if let Some(header) = entry.strip_prefix("## ") {
            status.branch = parse_branch(header);
            (status.ahead, status.behind) = parse_ahead_behind(header);
            status.has_upstream = header.contains("...");
            continue;
        }
        let Some((xy, path)) = split_entry(entry) else {
            continue;
        };
        let (x, y) = xy;
        let orig = if matches!(x, 'R' | 'C') || matches!(y, 'R' | 'C') {
            parts.next().filter(|s| !s.is_empty()).map(str::to_string)
        } else {
            None
        };
        let path = path.to_string();
        if x == '?' && y == '?' {
            status.unstaged.push(FileEntry {
                path,
                orig: None,
                letter: 'U',
            });
            continue;
        }
        if x == '!' {
            continue; // ignored file
        }
        if is_conflict(x, y) {
            status.unstaged.push(FileEntry {
                path,
                orig,
                letter: '!',
            });
            continue;
        }
        if x != ' ' {
            status.staged.push(FileEntry {
                path: path.clone(),
                orig: orig.clone(),
                letter: display_letter(x),
            });
        }
        if y != ' ' {
            status.unstaged.push(FileEntry {
                path,
                orig,
                letter: display_letter(y),
            });
        }
    }
    status
}

/// The repo-relative paths a stage under `prefix` should touch: the
/// WORKING-TREE side of `status` (already-staged entries need no re-adding),
/// deduped and ordered. `None` = the whole repository.
pub fn paths_under(status: &Status, prefix: Option<&str>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for entry in &status.unstaged {
        let rename_touches_prefix = entry
            .orig
            .as_deref()
            .is_some_and(|original| under(original, prefix));
        if !under(&entry.path, prefix) && !rename_touches_prefix {
            continue;
        }
        for path in std::iter::once(&entry.path).chain(entry.orig.iter()) {
            if !out.contains(path) {
                out.push(path.clone());
            }
        }
    }
    out.sort();
    out
}

/// Drop every path that sits AT or inside one of `nested` — the nested
/// repository roots that must not be staged from an outer repo.
pub fn drop_nested(paths: Vec<String>, nested: &[String]) -> Vec<String> {
    paths
        .into_iter()
        .filter(|path| !nested.iter().any(|root| under(path, Some(root))))
        .collect()
}

/// Path-prefix containment on `/`-separated repo-relative paths: equal, or a
/// real descendant. `None` contains everything.
pub fn under(path: &str, prefix: Option<&str>) -> bool {
    let Some(prefix) = prefix else { return true };
    let prefix = prefix.trim_end_matches('/');
    let path = path.trim_end_matches('/');
    path == prefix
        || (path.len() > prefix.len()
            && path.starts_with(prefix)
            && path.as_bytes()[prefix.len()] == b'/')
}

/// The `!!` entries of a `--ignored` porcelain run: repo-relative roots of
/// ignored files and (collapsed) ignored directories, trailing `/` stripped.
/// Rename source fields can never start with `!! `, so a plain scan is safe
/// without tracking the two-field rename shape.
pub fn parse_ignored(raw: &str) -> Vec<String> {
    raw.split('\0')
        .filter_map(|entry| entry.strip_prefix("!! "))
        .map(|path| path.trim_end_matches('/').to_string())
        .filter(|path| !path.is_empty())
        .collect()
}

/// `("XY", path)` from one porcelain entry; the XY columns are always ASCII.
fn split_entry(entry: &str) -> Option<((char, char), &str)> {
    let bytes = entry.as_bytes();
    if bytes.len() < 4 || bytes[2] != b' ' {
        return None;
    }
    Some(((bytes[0] as char, bytes[1] as char), &entry[3..]))
}

fn is_conflict(x: char, y: char) -> bool {
    matches!(
        (x, y),
        ('D', 'D') | ('A', 'U') | ('U', 'D') | ('U', 'A') | ('D', 'U') | ('A', 'A') | ('U', 'U')
    )
}

/// Type changes (T) read as plain modifications, matching VS Code.
fn display_letter(c: char) -> char {
    if c == 'T' { 'M' } else { c }
}

/// Branch from the `## …` header: `main...origin/main [ahead 1]`, bare `main`,
/// `No commits yet on main`, or `HEAD (no branch)` when detached.
fn parse_branch(header: &str) -> String {
    let head = header.split("...").next().unwrap_or(header);
    head.strip_prefix("No commits yet on ")
        .unwrap_or(head)
        .to_string()
}

/// `(ahead, behind)` from the header's `[ahead 1, behind 2]` suffix (either
/// half may be absent; `[gone]` and no-bracket headers give zeros).
fn parse_ahead_behind(header: &str) -> (usize, usize) {
    let Some(bracket) = header
        .rsplit_once('[')
        .map(|(_, b)| b.trim_end_matches(']'))
    else {
        return (0, 0);
    };
    let count_after = |tag: &str| {
        bracket
            .split(',')
            .map(str::trim)
            .find_map(|part| part.strip_prefix(tag))
            .and_then(|n| n.trim().parse().ok())
            .unwrap_or(0)
    };
    (count_after("ahead "), count_after("behind "))
}

/// Directories under `dir`, `depth` levels deep, skipping build/VCS internals
/// (the repo scan visits each).
fn child_dirs(dir: &Path, depth: usize) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if depth == 0 {
        return out;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return out;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if matches!(
            name.as_ref(),
            ".git" | "target" | "node_modules" | ".claude"
        ) {
            continue;
        }
        out.push(path.clone());
        out.extend(child_dirs(&path, depth - 1));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(path: &str, letter: char, orig: Option<&str>) -> FileEntry {
        FileEntry {
            path: path.to_string(),
            orig: orig.map(str::to_string),
            letter,
        }
    }

    #[test]
    fn parses_branch_variants() {
        assert_eq!(
            parse_status("## main...origin/main [ahead 1]\0").branch,
            "main"
        );
        assert_eq!(parse_status("## git-panel\0").branch, "git-panel");
        assert_eq!(parse_status("## No commits yet on trunk\0").branch, "trunk");
        assert_eq!(
            parse_status("## HEAD (no branch)\0").branch,
            "HEAD (no branch)"
        );
    }

    #[test]
    fn parses_ahead_behind_and_upstream() {
        let s = parse_status("## main...origin/main [ahead 3, behind 2]\0");
        assert_eq!((s.ahead, s.behind, s.has_upstream), (3, 2, true));
        let s = parse_status("## main...origin/main [behind 4]\0");
        assert_eq!((s.ahead, s.behind, s.has_upstream), (0, 4, true));
        let s = parse_status("## main...origin/main\0");
        assert_eq!((s.ahead, s.behind, s.has_upstream), (0, 0, true));
        let s = parse_status("## local-only\0");
        assert_eq!((s.ahead, s.behind, s.has_upstream), (0, 0, false));
        let s = parse_status("## main...origin/main [gone]\0");
        assert_eq!((s.ahead, s.behind), (0, 0));
    }

    #[test]
    fn discover_all_finds_child_repos_and_dedupes() {
        let base = std::env::temp_dir().join(format!("aa-git-scan-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        // base is NOT a repo; two children are (one nested two levels down),
        // and a `.git`-less child is ignored.
        for sub in ["a", "group/b", "plain"] {
            std::fs::create_dir_all(base.join(sub)).unwrap();
        }
        for repo in ["a", "group/b"] {
            std::process::Command::new("git")
                .args(["init", "-q"])
                .current_dir(base.join(repo))
                .output()
                .unwrap();
        }
        let repos = Git::discover_all(&base);
        let mut names: Vec<String> = repos.iter().map(|r| r.name()).collect();
        names.sort();
        assert_eq!(names, ["a", "b"]);
        let _ = std::fs::remove_dir_all(&base);
    }

    /// A fresh repo with one commit on `main`, so HEAD resolves.
    fn repo_with_head(name: &str) -> Git {
        let root =
            std::env::temp_dir().join(format!("aa-git-unstage-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        for args in [
            &["init", "-q"][..],
            &[
                "-c",
                "user.email=t@t.dev",
                "-c",
                "user.name=t",
                "commit",
                "--allow-empty",
                "-q",
                "-m",
                "init",
            ][..],
        ] {
            std::process::Command::new("git")
                .args(args)
                .current_dir(&root)
                .output()
                .unwrap();
        }
        Git { root }
    }

    #[test]
    fn unstage_all_propagates_reset_failure_instead_of_destructive_fallback_when_head_exists() {
        let git = repo_with_head("unstage-all");
        std::fs::write(git.root.join("file.txt"), "v1").unwrap();
        run_in(&git.root, &["add", "-A"]).unwrap();
        // Force `git reset` to fail deterministically without touching HEAD.
        std::fs::write(git.root.join(".git/index.lock"), "").unwrap();
        let result = git.unstage_all();
        std::fs::remove_file(git.root.join(".git/index.lock")).unwrap();
        assert!(
            result.is_err(),
            "a real reset failure must not report success"
        );
        let status = git.status().unwrap();
        assert_eq!(
            status.staged.len(),
            1,
            "file must still be staged, untouched"
        );
        assert_eq!(
            status.staged[0].letter, 'A',
            "must still be a staged add, not a staged deletion"
        );
        let _ = std::fs::remove_dir_all(&git.root);
    }

    #[test]
    fn unstage_all_falls_back_on_a_genuinely_unborn_branch() {
        let root =
            std::env::temp_dir().join(format!("aa-git-unstage-unborn-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::process::Command::new("git")
            .args(["init", "-q"])
            .current_dir(&root)
            .output()
            .unwrap();
        std::fs::write(root.join("file.txt"), "v1").unwrap();
        let git = Git { root: root.clone() };
        run_in(&git.root, &["add", "-A"]).unwrap();
        // No commits yet: `git reset` has no HEAD to reset against.
        assert!(!git.has_head());
        assert!(git.unstage_all().is_ok());
        let status = git.status().unwrap();
        assert_eq!(status.staged, vec![]);
        assert_eq!(status.unstaged, vec![entry("file.txt", 'U', None)]);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn splits_staged_and_unstaged_sides() {
        let s = parse_status("## main\0MM src/app.rs\0A  new.rs\0 D gone.rs\0");
        assert_eq!(
            s.staged,
            vec![entry("src/app.rs", 'M', None), entry("new.rs", 'A', None)]
        );
        assert_eq!(
            s.unstaged,
            vec![entry("src/app.rs", 'M', None), entry("gone.rs", 'D', None)]
        );
    }

    #[test]
    fn untracked_shows_as_u() {
        let s = parse_status("?? docs/notes.md\0");
        assert_eq!(s.staged, vec![]);
        assert_eq!(s.unstaged, vec![entry("docs/notes.md", 'U', None)]);
    }

    #[test]
    fn rename_consumes_the_source_field() {
        let s = parse_status("R  new_name.rs\0old_name.rs\0?? after.txt\0");
        assert_eq!(
            s.staged,
            vec![entry("new_name.rs", 'R', Some("old_name.rs"))]
        );
        assert_eq!(s.unstaged, vec![entry("after.txt", 'U', None)]);
    }

    #[test]
    fn type_change_reads_as_modified() {
        let s = parse_status("T  link.sh\0 T other.sh\0");
        assert_eq!(s.staged, vec![entry("link.sh", 'M', None)]);
        assert_eq!(s.unstaged, vec![entry("other.sh", 'M', None)]);
    }

    #[test]
    fn conflicts_land_unstaged_with_bang() {
        let s = parse_status("UU merge.rs\0AA both.rs\0");
        assert_eq!(s.staged, vec![]);
        assert_eq!(
            s.unstaged,
            vec![entry("merge.rs", '!', None), entry("both.rs", '!', None)]
        );
    }

    #[test]
    fn garbage_and_ignored_entries_are_skipped() {
        let s = parse_status("!! target\0x\0\0 M ok.rs\0");
        assert_eq!(s.staged, vec![]);
        assert_eq!(s.unstaged, vec![entry("ok.rs", 'M', None)]);
    }

    #[test]
    fn ignored_entries_parse_into_roots() {
        // `--untracked-files=normal` collapses an ignored directory to one
        // entry; the trailing slash goes so it compares like any other path.
        let raw = "## main\0!! target/\0!! build.log\0 M src/app.rs\0";
        assert_eq!(parse_ignored(raw), ["target", "build.log"]);
        assert_eq!(parse_ignored("## main\0"), Vec::<String>::new());
    }

    #[test]
    fn prefix_containment_is_path_aware() {
        assert!(under("src/app.rs", None), "no prefix contains everything");
        assert!(under("src/app.rs", Some("src")));
        assert!(under("src/app.rs", Some("src/app.rs")), "the path itself");
        assert!(under("src/api/routes.rs", Some("src")));
        assert!(
            !under("srcfoo/app.rs", Some("src")),
            "not a component boundary"
        );
        assert!(
            !under("src", Some("src/api")),
            "an ancestor is not under it"
        );
        assert!(!under("docs/x.md", Some("src")));
    }

    #[test]
    fn stage_candidates_are_the_working_tree_side_under_the_prefix() {
        let status = parse_status(
            "## main\0M  already-staged.rs\0 M src/app.rs\0?? src/new.rs\0 D src/gone.rs\0 M docs/x.md\0",
        );
        assert_eq!(
            paths_under(&status, Some("src")),
            ["src/app.rs", "src/gone.rs", "src/new.rs"],
            "modifications, deletions and untracked files alike"
        );
        assert_eq!(
            paths_under(&status, None),
            ["docs/x.md", "src/app.rs", "src/gone.rs", "src/new.rs"],
            "the whole repo, minus what is already staged"
        );
        assert_eq!(paths_under(&status, Some("nothing")), Vec::<String>::new());
    }

    #[test]
    fn stage_candidates_keep_both_sides_of_an_unstaged_rename() {
        let status = parse_status(" R src/new.rs\0src/old.rs\0 M docs/x.md\0");
        assert_eq!(
            paths_under(&status, Some("src")),
            ["src/new.rs", "src/old.rs"]
        );
        assert_eq!(
            paths_under(&status, Some("src/new.rs")),
            ["src/new.rs", "src/old.rs"],
            "staging the rename row must include its deleted source"
        );
    }

    #[test]
    fn nested_repo_paths_are_dropped_from_a_parent_stage() {
        let paths = vec![
            "src/app.rs".to_string(),
            "vendor/lib".to_string(),
            "vendor/lib/inner.rs".to_string(),
            "vendor/other.rs".to_string(),
        ];
        assert_eq!(
            drop_nested(paths, &["vendor/lib".to_string()]),
            ["src/app.rs", "vendor/other.rs"],
            "the nested root itself and everything inside it"
        );
    }

    /// A repo with an inner repo under `vendor/lib`, both dirty.
    fn nested_repo_fixture(tag: &str) -> (Git, Git) {
        let root = std::env::temp_dir().join(format!("aa-git-nested-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("src")).unwrap();
        std::fs::create_dir_all(root.join("vendor/lib")).unwrap();
        for dir in [root.clone(), root.join("vendor/lib")] {
            for args in [
                &["init", "-q"][..],
                &[
                    "-c",
                    "user.email=t@t.dev",
                    "-c",
                    "user.name=t",
                    "commit",
                    "--allow-empty",
                    "-q",
                    "-m",
                    "init",
                ][..],
            ] {
                std::process::Command::new("git")
                    .args(args)
                    .current_dir(&dir)
                    .output()
                    .unwrap();
            }
        }
        std::fs::write(root.join("src/app.rs"), "outer").unwrap();
        std::fs::write(root.join("vendor/note.txt"), "sibling").unwrap();
        std::fs::write(root.join("vendor/lib/inner.rs"), "inner").unwrap();
        (
            Git { root: root.clone() },
            Git {
                root: root.join("vendor/lib"),
            },
        )
    }

    #[test]
    fn staging_a_directory_stops_at_a_nested_repository_boundary() {
        let (outer, inner) = nested_repo_fixture("boundary");
        // Staging the whole outer repo must not reach into vendor/lib — not
        // even as the gitlink a bare `git add vendor` would record.
        let staged = outer.stage_under(&outer.root).unwrap();
        assert_eq!(staged.count, 2, "src/app.rs and vendor/note.txt only");
        assert_eq!(
            staged.skipped_nested, 1,
            "vendor/lib was skipped, not staged"
        );
        let status = outer.status().unwrap();
        let names: Vec<&str> = status.staged.iter().map(|e| e.path.as_str()).collect();
        assert_eq!(names, ["src/app.rs", "vendor/note.txt"]);
        assert!(
            !status
                .staged
                .iter()
                .any(|e| e.path.starts_with("vendor/lib")),
            "no gitlink for the embedded repo: {names:?}"
        );
        // The inner repo is untouched, and stages independently.
        assert!(inner.status().unwrap().staged.is_empty());
        assert_eq!(
            inner.stage_under(&inner.root).unwrap(),
            Staged {
                count: 1,
                skipped_nested: 0
            }
        );
        assert_eq!(inner.status().unwrap().staged[0].path, "inner.rs");
        let _ = std::fs::remove_dir_all(&outer.root);
    }

    #[test]
    fn owner_of_resolves_to_the_nearest_enclosing_repository() {
        let (outer, inner) = nested_repo_fixture("owner");
        let outer_root = std::fs::canonicalize(&outer.root).unwrap();
        let inner_root = std::fs::canonicalize(&inner.root).unwrap();
        assert_eq!(
            std::fs::canonicalize(Git::owner_of(&outer.root.join("src/app.rs")).unwrap().root)
                .unwrap(),
            outer_root
        );
        assert_eq!(
            std::fs::canonicalize(Git::owner_of(&outer.root.join("src")).unwrap().root).unwrap(),
            outer_root
        );
        // Inside the nested checkout the INNER repo owns the path.
        assert_eq!(
            std::fs::canonicalize(Git::owner_of(&inner.root.join("inner.rs")).unwrap().root)
                .unwrap(),
            inner_root
        );
        assert_eq!(
            std::fs::canonicalize(Git::owner_of(&inner.root).unwrap().root).unwrap(),
            inner_root
        );
        let _ = std::fs::remove_dir_all(&outer.root);
    }

    #[test]
    fn staging_covers_additions_modifications_and_deletions() {
        let git = repo_with_head("stage-kinds");
        std::fs::create_dir_all(git.root.join("src")).unwrap();
        std::fs::write(git.root.join("src/tracked.rs"), "v1").unwrap();
        std::fs::write(git.root.join("src/removed.rs"), "v1").unwrap();
        std::fs::write(git.root.join("other.rs"), "v1").unwrap();
        run_in(&git.root, &["add", "-A"]).unwrap();
        run_in(
            &git.root,
            &[
                "-c",
                "user.email=t@t.dev",
                "-c",
                "user.name=t",
                "commit",
                "-q",
                "-m",
                "base",
            ],
        )
        .unwrap();
        std::fs::write(git.root.join("src/tracked.rs"), "v2").unwrap();
        std::fs::remove_file(git.root.join("src/removed.rs")).unwrap();
        std::fs::write(git.root.join("src/added.rs"), "new").unwrap();
        std::fs::write(git.root.join("other.rs"), "v2").unwrap();

        assert_eq!(git.stage_under(&git.root.join("src")).unwrap().count, 3);
        let status = git.status().unwrap();
        let staged: Vec<(&str, char)> = status
            .staged
            .iter()
            .map(|e| (e.path.as_str(), e.letter))
            .collect();
        assert_eq!(
            staged,
            [
                ("src/added.rs", 'A'),
                ("src/removed.rs", 'D'),
                ("src/tracked.rs", 'M')
            ]
        );
        assert_eq!(
            status
                .unstaged
                .iter()
                .map(|e| e.path.as_str())
                .collect::<Vec<_>>(),
            ["other.rs"],
            "a sibling outside the staged directory stays untouched"
        );
        // Nothing left to stage there.
        assert_eq!(git.stage_under(&git.root.join("src")).unwrap().count, 0);
        let _ = std::fs::remove_dir_all(&git.root);
    }

    #[test]
    fn staging_a_directory_records_a_rename_not_only_its_destination() {
        let git = repo_with_head("stage-rename");
        std::fs::create_dir_all(git.root.join("src")).unwrap();
        std::fs::write(git.root.join("src/old.rs"), "tracked").unwrap();
        run_in(&git.root, &["add", "-A"]).unwrap();
        run_in(
            &git.root,
            &[
                "-c",
                "user.email=t@t.dev",
                "-c",
                "user.name=t",
                "commit",
                "-q",
                "-m",
                "base",
            ],
        )
        .unwrap();
        run_in(&git.root, &["config", "status.renames", "true"]).unwrap();
        std::fs::rename(git.root.join("src/old.rs"), git.root.join("src/new.rs")).unwrap();
        run_in(&git.root, &["add", "-N", "src/new.rs"]).unwrap();

        let before = git.status().unwrap();
        assert_eq!(before.unstaged[0].orig.as_deref(), Some("src/old.rs"));
        assert_eq!(git.stage_under(&git.root.join("src")).unwrap().count, 2);

        let staged = git.status().unwrap();
        assert!(staged.unstaged.is_empty(), "both rename sides were staged");
        assert_eq!(staged.staged[0].path, "src/new.rs");
        assert_eq!(staged.staged[0].orig.as_deref(), Some("src/old.rs"));
        let _ = std::fs::remove_dir_all(&git.root);
    }

    #[test]
    fn staging_a_rename_row_records_both_sides() {
        let git = repo_with_head("stage-rename-row");
        std::fs::create_dir_all(git.root.join("src")).unwrap();
        std::fs::write(git.root.join("src/old.rs"), "tracked").unwrap();
        run_in(&git.root, &["add", "-A"]).unwrap();
        run_in(
            &git.root,
            &[
                "-c",
                "user.email=t@t.dev",
                "-c",
                "user.name=t",
                "commit",
                "-q",
                "-m",
                "base",
            ],
        )
        .unwrap();
        std::fs::rename(git.root.join("src/old.rs"), git.root.join("src/new.rs")).unwrap();
        run_in(&git.root, &["add", "-N", "src/new.rs"]).unwrap();

        let entry = git
            .status()
            .unwrap()
            .unstaged
            .into_iter()
            .find(|entry| entry.orig.is_some())
            .unwrap();
        git.stage(&entry).unwrap();

        let status = git.status().unwrap();
        assert!(status.unstaged.is_empty(), "both rename sides were staged");
        assert_eq!(status.staged[0].path, "src/new.rs");
        assert_eq!(status.staged[0].orig.as_deref(), Some("src/old.rs"));
        let _ = std::fs::remove_dir_all(&git.root);
    }

    #[test]
    fn staging_a_single_file_stages_only_that_file() {
        let git = repo_with_head("stage-one");
        std::fs::create_dir_all(git.root.join("src")).unwrap();
        std::fs::write(git.root.join("src/a.rs"), "a").unwrap();
        std::fs::write(git.root.join("src/b.rs"), "b").unwrap();
        assert_eq!(
            git.stage_under(&git.root.join("src/a.rs")).unwrap().count,
            1
        );
        let status = git.status().unwrap();
        assert_eq!(
            status
                .staged
                .iter()
                .map(|e| e.path.as_str())
                .collect::<Vec<_>>(),
            ["src/a.rs"]
        );
        assert_eq!(
            status
                .unstaged
                .iter()
                .map(|e| e.path.as_str())
                .collect::<Vec<_>>(),
            ["src/b.rs"]
        );
        let _ = std::fs::remove_dir_all(&git.root);
    }

    #[test]
    fn staging_refuses_a_target_outside_the_repository() {
        let git = Git {
            root: std::env::temp_dir().join("stage-boundary-repo"),
        };
        let outside = std::env::temp_dir().join("stage-boundary-other");
        let error = git.stage_under(&outside).unwrap_err();
        assert!(error.contains("outside repository"), "{error}");
    }

    #[test]
    fn ignored_lists_the_repos_ignored_roots() {
        let git = repo_with_head("ignored");
        std::fs::write(git.root.join(".gitignore"), "target/\n*.log\n").unwrap();
        std::fs::create_dir_all(git.root.join("target/debug")).unwrap();
        std::fs::write(git.root.join("target/debug/app.exe"), "bin").unwrap();
        std::fs::write(git.root.join("build.log"), "noise").unwrap();
        let mut ignored = git.ignored().unwrap();
        ignored.sort();
        assert_eq!(
            ignored,
            ["build.log", "target"],
            "the ignored dir stays collapsed"
        );
        // Ignored paths are never stage candidates.
        assert_eq!(
            paths_under(&git.status().unwrap(), None),
            [".gitignore"],
            "only the non-ignored file is a candidate"
        );
        let _ = std::fs::remove_dir_all(&git.root);
    }

    #[test]
    fn paths_with_spaces_survive() {
        let s = parse_status("M  my docs/read me.md\0");
        assert_eq!(s.staged, vec![entry("my docs/read me.md", 'M', None)]);
    }
}
