use std::io;
use std::path::{Path, PathBuf};

use crate::embed::SidebarContext;
use crate::state;

pub fn is_plugin_hook_cwd(path: &str) -> bool {
    let path = path.trim();
    if path.is_empty() {
        return false;
    }
    if path.ends_with("-dev.layout") {
        return true;
    }
    let Some(suffix) = plugin_hook_cwd_suffix() else {
        return false;
    };
    path.ends_with(&suffix)
}

pub fn is_plausible_root(path: &str) -> bool {
    let path = path.trim();
    !path.is_empty() && !is_plugin_hook_cwd(path) && Path::new(path).is_dir()
}

fn plausible_path(path: &Path) -> bool {
    path.to_str().is_some_and(is_plausible_root)
}

pub fn resolve_startup_root(workspace_label: &str, ctx: SidebarContext) -> io::Result<PathBuf> {
    if ctx.embedded() {
        if let Some(workdir) = state::layout_workdir().filter(|r| plausible_path(r)) {
            state::save_root(workspace_label, &workdir);
            return Ok(workdir);
        }
        if let Some(root) = state::load_root(workspace_label).filter(|r| plausible_path(r)) {
            return Ok(root);
        }
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "embedded sidebar: layout workdir unavailable",
        ));
    }
    let root = state::load_root(workspace_label)
        .filter(|r| plausible_path(r))
        .or_else(|| std::env::current_dir().ok().filter(|r| plausible_path(r)))
        .unwrap_or_else(|| PathBuf::from("."));
    state::save_root(workspace_label, &root);
    Ok(root)
}

pub fn expand_folder_input(raw: &str, current_root: &Path) -> PathBuf {
    let expanded = match raw.strip_prefix('~') {
        Some(rest) => {
            let home = std::env::var("USERPROFILE")
                .or_else(|_| std::env::var("HOME"))
                .unwrap_or_default();
            format!("{home}{rest}")
        }
        None => raw.to_string(),
    };
    let target = PathBuf::from(expanded);
    if target.is_relative() {
        current_root.join(target)
    } else {
        target
    }
}

pub enum FolderApply {
    Applied(PathBuf),
    Rejected { message: Option<String> },
}

pub fn apply_folder(raw: &str, current_root: &Path, manual: bool) -> FolderApply {
    let raw = raw.trim();
    if raw.is_empty() {
        return FolderApply::Rejected {
            message: manual.then(|| "empty path".into()),
        };
    }
    if is_plugin_hook_cwd(raw) {
        return FolderApply::Rejected { message: None };
    }
    let target = expand_folder_input(raw, current_root);
    let path_str = target.as_os_str().to_str().unwrap_or("");
    if is_plugin_hook_cwd(path_str) {
        return FolderApply::Rejected { message: None };
    }
    if !is_plausible_root(path_str) || std::env::set_current_dir(&target).is_err() {
        return FolderApply::Rejected {
            message: manual.then(|| format!("not a folder: {raw}")),
        };
    }
    FolderApply::Applied(std::env::current_dir().unwrap_or(target))
}

pub fn follow_sibling_target(raw: &str, current_root: &Path) -> Option<PathBuf> {
    if is_plugin_hook_cwd(raw) {
        return None;
    }
    match apply_folder(raw, current_root, false) {
        FolderApply::Applied(root) if root != current_root => Some(root),
        _ => None,
    }
}

fn plugin_hook_cwd_suffix() -> Option<String> {
    let id = std::env::var("AGENTIC_LAYOUT_PLUGIN_ID").ok()?;
    let tail = id.strip_prefix("agentic-").unwrap_or(id.as_str());
    Some(format!("-{tail}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hook_cwd_matches_plugin_suffix() {
        assert!(is_plugin_hook_cwd("/tmp/proj-dev.layout"));
        unsafe { std::env::set_var("AGENTIC_LAYOUT_PLUGIN_ID", "agentic-dev.layout") };
        assert!(is_plugin_hook_cwd("/tmp/work/agentic-dev-setup-dev.layout"));
        unsafe { std::env::remove_var("AGENTIC_LAYOUT_PLUGIN_ID") };
    }

    #[test]
    fn apply_folder_rejects_hook_cwd_silently_even_when_manual() {
        assert!(matches!(
            apply_folder(
                "/tmp/work/agentic-dev-setup-dev.layout",
                Path::new("/tmp"),
                true
            ),
            FolderApply::Rejected { message: None }
        ));
    }

    #[test]
    fn plausible_root_requires_existing_dir() {
        let tmp = std::env::temp_dir().join(format!("sidebar-root-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        assert!(is_plausible_root(tmp.to_str().unwrap()));
        assert!(!is_plausible_root(&format!("{}-dev.layout", tmp.display())));
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
