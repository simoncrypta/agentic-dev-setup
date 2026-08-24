//! Git status decorations for the Explorer tree (issue #19): a lookup from an
//! absolute path to the status letter it should be decorated with, plus the
//! dirty-directory aggregation that makes changes visible while a folder is
//! still collapsed.
//!
//! The vocabulary is deliberately the Source Control view's own — the letters
//! [`crate::git::parse_status`] produces (`M`/`A`/`D`/`R`/`C`, `U` untracked,
//! `!` conflict) — with one addition, `I` for ignored, so the two views can
//! never disagree about what a status means. Colors come from
//! [`crate::ui::status_color`].

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::git::Status;

/// How "loud" a status is when several compete for one row: a conflict wins
/// over a tracked change, which wins over an untracked file. Mirrors VS Code,
/// where a folder holding a conflict reads red even if most of it is merely
/// modified.
fn rank(letter: char) -> u8 {
    match letter {
        '!' => 3,
        'M' | 'A' | 'D' | 'R' | 'C' => 2,
        'U' => 1,
        _ => 0,
    }
}

/// The single letter a directory carries when its descendants are changed:
/// the loudest descendant status, collapsed to conflict / changed / untracked.
fn dir_letter(letter: char) -> char {
    match rank(letter) {
        3 => '!',
        2 => 'M',
        _ => 'U',
    }
}

/// Absolute path for a `/`-separated repo-relative path. Built component by
/// component on purpose: `root.join("a/b")` keeps the forward slash on
/// Windows, and would never compare equal to the tree's `root\a\b` rows.
fn abs(root: &Path, rel: &str) -> PathBuf {
    rel.split('/')
        .filter(|part| !part.is_empty())
        .fold(root.to_path_buf(), |acc, part| acc.join(part))
}

/// One repository's contribution to the decorations.
pub struct RepoStatus {
    pub root: PathBuf,
    pub status: Status,
    /// Repo-relative ignored roots (see [`crate::git::Git::ignored`]).
    pub ignored: Vec<String>,
}

#[derive(Default)]
pub struct Decorations {
    /// Changed FILES (every path git named directly), by absolute path.
    files: HashMap<PathBuf, char>,
    /// Directories with changed descendants, by absolute path.
    dirs: HashMap<PathBuf, char>,
    /// Ignored roots: a path is ignored when it IS one or lives under one.
    ignored: Vec<PathBuf>,
}

impl Decorations {
    /// No decorations at all — the "Git decorations: off" and no-repo cases.
    pub fn empty() -> Self {
        Self::default()
    }

    pub fn is_empty(&self) -> bool {
        self.files.is_empty() && self.dirs.is_empty() && self.ignored.is_empty()
    }

    /// Build the index from every repository the Explorer can see. Staged
    /// entries are folded in first so an equally loud WORKING-TREE status
    /// wins the row — that is the state the user sees on disk.
    pub fn build(repos: &[RepoStatus]) -> Self {
        let mut deco = Self::default();
        for repo in repos {
            for side in [&repo.status.staged, &repo.status.unstaged] {
                for entry in side {
                    deco.add(&repo.root, &entry.path, entry.letter);
                    // A rename's source is gone from its old location.
                    if let Some(orig) = &entry.orig {
                        deco.add(&repo.root, orig, 'D');
                    }
                }
            }
            for path in &repo.ignored {
                deco.ignored.push(abs(&repo.root, path));
            }
        }
        deco
    }

    fn add(&mut self, root: &Path, rel: &str, letter: char) {
        let path = abs(root, rel);
        // A later, equally loud status REPLACES the earlier one — which is
        // how the working-tree side wins over the staged side.
        let quieter = self
            .files
            .get(&path)
            .is_some_and(|e| rank(*e) > rank(letter));
        if !quieter {
            self.files.insert(path.clone(), letter);
        }
        let mark = dir_letter(letter);
        let mut parent = path.parent();
        while let Some(dir) = parent {
            if !dir.starts_with(root) {
                break;
            }
            let louder = self.dirs.get(dir).is_some_and(|e| rank(*e) >= rank(mark));
            if !louder {
                self.dirs.insert(dir.to_path_buf(), mark);
            }
            if dir == root {
                break;
            }
            parent = dir.parent();
        }
    }

    /// The status letter to decorate `path` with, if any. Directories report
    /// their aggregate; ignored paths report `I` unless they carry a real
    /// status of their own (a force-added ignored file still shows as
    /// modified, like VS Code).
    pub fn letter(&self, path: &Path, is_dir: bool) -> Option<char> {
        let own = self.files.get(path).copied();
        // A directory can appear on BOTH sides: git names an embedded repo
        // directly (`?? vendor/lib/` with `-uall`) while the nested repo's own
        // status makes it dirty. Show the louder of the two, so the folder
        // never reads as merely untracked when there are real changes in it.
        let aggregate = is_dir.then(|| self.dirs.get(path).copied()).flatten();
        let letter = match (own, aggregate) {
            (Some(a), Some(b)) => Some(if rank(b) > rank(a) { b } else { a }),
            (a, b) => a.or(b),
        };
        letter.or_else(|| self.is_ignored(path).then_some('I'))
    }

    fn is_ignored(&self, path: &Path) -> bool {
        self.ignored.iter().any(|root| path.starts_with(root))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::git::parse_status;

    fn repo(root: &str, porcelain: &str, ignored: &[&str]) -> RepoStatus {
        RepoStatus {
            root: PathBuf::from(root),
            status: parse_status(porcelain),
            ignored: ignored.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn root() -> PathBuf {
        PathBuf::from("/ws")
    }

    fn at(deco: &Decorations, rel: &str, is_dir: bool) -> Option<char> {
        deco.letter(&abs(&root(), rel), is_dir)
    }

    #[test]
    fn files_carry_their_status_letter() {
        let deco = Decorations::build(&[repo(
            "/ws",
            "## main\0 M src/app.rs\0A  new.rs\0?? notes.md\0 D gone.rs\0UU merge.rs\0",
            &[],
        )]);
        assert_eq!(at(&deco, "src/app.rs", false), Some('M'));
        assert_eq!(at(&deco, "new.rs", false), Some('A'));
        assert_eq!(at(&deco, "notes.md", false), Some('U'));
        assert_eq!(at(&deco, "gone.rs", false), Some('D'));
        assert_eq!(at(&deco, "merge.rs", false), Some('!'));
        assert_eq!(at(&deco, "untouched.rs", false), None);
    }

    #[test]
    fn working_tree_side_wins_over_an_equally_loud_staged_side() {
        // MM = staged modification plus a further working-tree modification.
        let deco = Decorations::build(&[repo("/ws", "## main\0MM src/app.rs\0", &[])]);
        assert_eq!(at(&deco, "src/app.rs", false), Some('M'));
        // AD = staged add, deleted again in the working tree: the equally
        // loud worktree deletion is the state on disk.
        let deco = Decorations::build(&[repo("/ws", "## main\0AD later.rs\0", &[])]);
        assert_eq!(at(&deco, "later.rs", false), Some('D'));
    }

    #[test]
    fn directories_aggregate_their_descendants() {
        let deco = Decorations::build(&[repo("/ws", "## main\0 M src/api/routes.rs\0", &[])]);
        assert_eq!(at(&deco, "src/api", true), Some('M'), "immediate parent");
        assert_eq!(at(&deco, "src", true), Some('M'), "and every ancestor");
        assert_eq!(at(&deco, "", true), Some('M'), "up to the repo root");
        assert_eq!(
            at(&deco, "docs", true),
            None,
            "untouched siblings stay clean"
        );
    }

    #[test]
    fn directory_aggregate_takes_the_loudest_descendant() {
        let deco = Decorations::build(&[repo(
            "/ws",
            "## main\0?? src/scratch.txt\0 M src/app.rs\0",
            &[],
        )]);
        assert_eq!(
            at(&deco, "src", true),
            Some('M'),
            "a tracked change outranks an untracked sibling"
        );
        let deco = Decorations::build(&[repo(
            "/ws",
            "## main\0 M src/app.rs\0UU src/merge.rs\0",
            &[],
        )]);
        assert_eq!(
            at(&deco, "src", true),
            Some('!'),
            "a conflict outranks everything"
        );
        let deco = Decorations::build(&[repo("/ws", "## main\0?? src/scratch.txt\0", &[])]);
        assert_eq!(
            at(&deco, "src", true),
            Some('U'),
            "untracked-only stays green"
        );
    }

    #[test]
    fn a_rows_own_letter_beats_the_directory_aggregate() {
        let deco = Decorations::build(&[repo("/ws", "## main\0 D src/app.rs\0", &[])]);
        assert_eq!(at(&deco, "src/app.rs", false), Some('D'));
        assert_eq!(at(&deco, "src", true), Some('M'), "aggregate, not 'D'");
    }

    #[test]
    fn ignored_roots_cover_their_contents_without_dirtying_ancestors() {
        let deco = Decorations::build(&[repo("/ws", "## main\0", &["target", "notes.log"])]);
        assert_eq!(at(&deco, "target", true), Some('I'));
        assert_eq!(at(&deco, "target/debug/x.exe", false), Some('I'));
        assert_eq!(at(&deco, "notes.log", false), Some('I'));
        assert_eq!(at(&deco, "src", true), None);
        assert_eq!(
            at(&deco, "", true),
            None,
            "the root is not dirty from ignores"
        );
    }

    #[test]
    fn a_real_status_outranks_ignored() {
        // `git add -f` on an ignored file: both ignored and staged.
        let deco = Decorations::build(&[repo("/ws", "## main\0M  build.log\0", &["build.log"])]);
        assert_eq!(at(&deco, "build.log", false), Some('M'));
    }

    #[test]
    fn renames_decorate_both_ends() {
        let deco = Decorations::build(&[repo("/ws", "## main\0R  src/new.rs\0src/old.rs\0", &[])]);
        assert_eq!(at(&deco, "src/new.rs", false), Some('R'));
        assert_eq!(at(&deco, "src/old.rs", false), Some('D'));
    }

    #[test]
    fn nested_repos_decorate_independently_without_leaking_upward() {
        // The inner repo's changes are indexed under ITS root; the outer
        // repo's status never mentions them, so the outer tree above the
        // boundary stays clean.
        let deco = Decorations::build(&[
            repo("/ws", "## main\0 M outer.rs\0", &[]),
            repo("/ws/vendor/lib", "## main\0 M inner.rs\0", &[]),
        ]);
        assert_eq!(at(&deco, "outer.rs", false), Some('M'));
        assert_eq!(at(&deco, "vendor/lib/inner.rs", false), Some('M'));
        assert_eq!(
            at(&deco, "vendor/lib", true),
            Some('M'),
            "the nested repo root is dirty in its own right"
        );
        assert_eq!(
            at(&deco, "vendor", true),
            None,
            "but the outer repo's folders above the boundary stay clean"
        );
    }

    #[test]
    fn an_embedded_repo_folder_shows_its_own_changes_not_just_untracked() {
        // `-uall` names an embedded repository directly, so the outer repo
        // calls `vendor/lib` untracked while the inner repo reports real
        // changes inside it. The louder status wins.
        let deco = Decorations::build(&[
            repo("/ws", "## main\0?? vendor/lib/\0", &[]),
            repo("/ws/vendor/lib", "## main\0 M inner.rs\0", &[]),
        ]);
        assert_eq!(at(&deco, "vendor/lib", true), Some('M'));
        // With nothing changed inside, it stays plain untracked.
        let deco = Decorations::build(&[repo("/ws", "## main\0?? vendor/lib/\0", &[])]);
        assert_eq!(at(&deco, "vendor/lib", true), Some('U'));
    }

    #[test]
    fn empty_decorations_decorate_nothing() {
        let deco = Decorations::empty();
        assert!(deco.is_empty());
        assert_eq!(at(&deco, "src/app.rs", false), None);
    }
}
