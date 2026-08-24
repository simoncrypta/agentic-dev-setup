//! Sidebar ensure/toggle, driven entirely over the socket API (see `ipc`) so a
//! focus-event hook never spawns a console process. Mirrors the unix shell
//! scripts' flow; the decision/plan parsing is the unit-tested `launch` module,
//! fed the socket responses (same JSON the CLI prints).

use std::path::PathBuf;

use crate::{ipc, launch};

/// Serialize concurrent runs (pane/tab events arrive in bursts; unguarded,
/// one switch opened four panes).
/// Losing the race skips this run; the next event re-fires it.
struct Lock(PathBuf);

impl Lock {
    fn acquire(wait: bool) -> Option<Self> {
        let dir = std::env::temp_dir().join("herdr-sidebar-ensure.lock");
        let attempts = if wait { 20 } else { 0 };
        for attempt in 0..=attempts {
            if std::fs::create_dir(&dir).is_ok() {
                return Some(Self(dir));
            }
            // Break locks older than 30s (a crashed run), otherwise yield or
            // wait for a discrete action that must not be dropped.
            let stale = std::fs::metadata(&dir)
                .and_then(|m| m.created().or_else(|_| m.modified()))
                .ok()
                .and_then(|t| t.elapsed().ok())
                .is_some_and(|age| age.as_secs() > 30);
            if stale {
                let _ = std::fs::remove_dir_all(&dir);
                if std::fs::create_dir(&dir).is_ok() {
                    return Some(Self(dir));
                }
            }
            if attempt < attempts {
                std::thread::sleep(std::time::Duration::from_millis(500));
            }
        }
        None
    }
}

impl Drop for Lock {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir(&self.0);
    }
}

use crate::snooze;

/// Quiet mode (hooks): make sure the focused tab has an Explorer, never moving
/// focus, and respecting a tab the user toggled closed. Toggle mode (the
/// action): open-or-focus-or-close, like VS Code's explorer shortcut.
pub fn run(toggle: bool, git: bool) -> std::io::Result<()> {
    // Auto-open off (⚙ Settings): hooks leave closed tabs alone; the user's
    // explicit toggle still works. The unix hook script makes the same check
    // via `herdr-sidebar --auto-open`.
    if !toggle && !crate::state::load_state().auto_open {
        return Ok(());
    }
    let event_json = std::env::var("HERDR_PLUGIN_EVENT_JSON").unwrap_or_default();
    let wait_for_lock = must_wait_for_lock(toggle, &event_json);
    let Some(_lock) = Lock::acquire(wait_for_lock) else {
        return Ok(());
    };
    let mut panes = ipc::call_text("pane.list", serde_json::json!({}))?;
    // The tab THIS event is about. During a workspace switch the globally
    // focused pane is still the space you came from, which docked sidebars
    // into the wrong project (the unix hook script scopes the same way, via
    // `--event-scope`). A toggle is a deliberate act on the focused tab, so
    // it stays unscoped.
    let scope = if toggle {
        String::new()
    } else {
        launch::event_scope(&event_json)
    };
    let tab = snooze_tab_for_scope(&panes, &scope);
    let snooze_dir = snooze::dir();
    snooze::sweep(&snooze_dir, &launch::live_tabs(&panes));
    let now = crate::state::unix_now();
    let decision = if git {
        launch::launch_decision_git(&panes, now)
    } else {
        launch::launch_decision_in(&panes, now, &scope)
    };
    match decision.split_once(' ') {
        Some(("FOCUS", id)) => {
            if toggle {
                focus(id)?;
            }
        }
        Some(("CLOSE", id)) => {
            if toggle {
                ipc::call_text("pane.close", serde_json::json!({ "pane_id": id }))?;
                snooze::set(&snooze_dir, &tab);
            }
        }
        Some(("REPLACE", id)) => {
            // A dead pane (stale heartbeat): close it and dock a fresh one,
            // quiet or toggle alike — a corpse should never block the dock.
            ipc::call_text("pane.close", serde_json::json!({ "pane_id": id }))?;
            // Closing a focused corpse changes focus and invalidates its pane
            // id. Re-plan from a fresh snapshot rather than splitting a pane
            // that no longer exists.
            panes = ipc::call_text("pane.list", serde_json::json!({}))?;
            open(&panes, toggle, &scope, git)?;
        }
        _ => {
            if toggle {
                snooze::clear(&snooze_dir, &tab);
                open(&panes, true, &scope, git)?;
            } else if !snooze::is_set(&snooze_dir, &tab) {
                open(&panes, false, &scope, git)?;
            }
        }
    }
    Ok(())
}

fn snooze_tab_for_scope(panes_json: &str, scope: &str) -> String {
    if scope.contains(':') {
        scope.to_string()
    } else if scope.is_empty() {
        launch::focused_tab(panes_json)
    } else {
        String::new()
    }
}

fn focus(pane_id: &str) -> std::io::Result<()> {
    // The API has focus-by-id (`pane.focus`), unlike the CLI's zoom-cycle hack.
    ipc::call_text("pane.focus", serde_json::json!({ "pane_id": pane_id }))?;
    Ok(())
}

fn open(panes_json: &str, focus_new: bool, scope: &str, git: bool) -> std::io::Result<()> {
    // Root the new sidebar from a pane in the scope we are docking into —
    // the decision above answered for that scope, and the two must agree or
    // we dock into one tab with another tab's cwd.
    let fp = launch::focused_pane_in(panes_json, scope);
    let Some((fid, fcwd)) = fp.split_once('\t') else {
        return Ok(());
    };

    let state = crate::state::load_state();
    let dock_right = state.dock_right;
    let layout = ipc::call_text("pane.layout", serde_json::json!({ "pane_id": fid }))?;
    let plan = launch::open_plan(&layout, dock_right, state.sidebar_width);
    let mut fields = plan.split('\t');
    let target = fields
        .next()
        .filter(|s| !s.is_empty())
        .unwrap_or(fid)
        .to_string();
    let ratio = fields
        .next()
        .and_then(|r| r.parse::<f64>().ok())
        .unwrap_or(if dock_right { 0.75 } else { 0.25 });
    let needs_swap = fields
        .next()
        .and_then(|s| s.parse::<bool>().ok())
        .unwrap_or(!dock_right);

    let mut split = serde_json::json!({
        "target_pane_id": target,
        "direction": "right",
        "ratio": ratio,
        "focus": false,
    });
    if !fcwd.is_empty() {
        split["cwd"] = serde_json::Value::String(fcwd.to_string());
    }
    split["env"] = crate::state::spawn_env();
    let response = ipc::call_text("pane.split", split)?;
    let Some(new_pane) = launch::split_pane_id(&response) else {
        return Ok(());
    };

    if needs_swap {
        ipc::call_text(
            "pane.swap",
            serde_json::json!({ "source_pane_id": new_pane, "target_pane_id": target }),
        )?;
    }
    let command = if git {
        format!("{} --view git", crate::state::EXECUTABLE_NAME)
    } else {
        crate::state::EXECUTABLE_NAME.to_string()
    };
    let label = if git {
        launch::SC_PANE_LABEL
    } else {
        launch::PANE_LABEL
    };
    ipc::call_text(
        "pane.send_input",
        serde_json::json!({
            "pane_id": new_pane,
            "text": command,
            "keys": ["Enter"]
        }),
    )?;
    ipc::call_text(
        "pane.rename",
        serde_json::json!({ "pane_id": new_pane, "label": label }),
    )?;
    full_height_repair(&new_pane, dock_right);

    // Hold the lock until the TUI stamps its identity token (~1-2s): hook
    // invocations queued behind us must observe a LIVE pane, or the
    // corpse rule would replace this spawn before it finishes booting.
    for _ in 0..30 {
        std::thread::sleep(std::time::Duration::from_millis(200));
        if let Ok(json) = ipc::call_text("pane.list", serde_json::json!({}))
            && launch::pane_has_token(&json, &new_pane)
        {
            break;
        }
    }

    if focus_new {
        focus(&new_pane)?;
    } else {
        // Quiet mode must never move focus, but the split/swap can (focus
        // follows the SLOT, not the pane) — unconditionally restore the pane
        // that was focused when we started.
        focus(fid)?;
    }
    Ok(())
}

/// Grow the freshly-opened explorer into a full-height edge column. When the
/// tab's chosen edge was already split vertically, the explorer only gets the
/// top slot; each repair step re-parents the pane below it as a down-split of
/// the pane beside it. herdr no-ops same-tab moves, so each step bounces the
/// pane through a temporary tab (herdr auto-closes it once emptied).
/// Best-effort: any miss just leaves the layout as it was.
fn full_height_repair(pane_id: &str, dock_right: bool) {
    for _ in 0..4 {
        let Ok(layout) = ipc::call_text("pane.layout", serde_json::json!({ "pane_id": pane_id }))
        else {
            return;
        };
        let Some(step) = launch::repair_step(&layout, pane_id, dock_right) else {
            return;
        };
        let bounced = ipc::call_text(
            "pane.move",
            serde_json::json!({
                "pane_id": step.below,
                "destination": { "type": "new_tab" },
                "focus": false,
            }),
        );
        if bounced.is_err() {
            return;
        }
        let _ = ipc::call_text(
            "pane.move",
            serde_json::json!({
                "pane_id": step.below,
                "destination": {
                    "type": "tab",
                    "tab_id": step.tab,
                    "target_pane_id": step.beside,
                    "split": "down",
                },
                "focus": false,
            }),
        );
    }
}

fn must_wait_for_lock(toggle: bool, event_json: &str) -> bool {
    toggle || launch::event_kind(event_json) == "tab_created"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snooze_set_clear_and_sweep() {
        let dir = std::env::temp_dir().join(format!("aa-ft-snooze-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        snooze::set(&dir, "w1:t1");
        snooze::set(&dir, "w1:t2");
        assert!(snooze::is_set(&dir, "w1:t1"));
        assert!(!snooze::is_set(&dir, "w1:t9"));
        assert!(!snooze::is_set(&dir, ""), "empty tab id never snoozes");

        snooze::clear(&dir, "w1:t1");
        assert!(!snooze::is_set(&dir, "w1:t1"));

        // Sweep drops markers for tabs that no longer exist.
        let live = std::collections::BTreeSet::from(["w1:t3".to_string()]);
        snooze::sweep(&dir, &live);
        assert!(!snooze::is_set(&dir, "w1:t2"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn workspace_events_do_not_borrow_the_globally_focused_tabs_snooze() {
        let panes = r#"{"result":{"panes":[
            {"pane_id":"w1:p1","tab_id":"w1:t1","focused":true},
            {"pane_id":"w2:p1","tab_id":"w2:t1"}
        ]}}"#;
        assert_eq!(snooze_tab_for_scope(panes, ""), "w1:t1");
        assert_eq!(snooze_tab_for_scope(panes, "w2:t1"), "w2:t1");
        assert_eq!(snooze_tab_for_scope(panes, "w2"), "");
    }

    #[test]
    fn discrete_tab_creation_and_manual_toggles_wait_for_the_lock() {
        assert!(must_wait_for_lock(false, r#"{"event":"tab_created"}"#));
        assert!(must_wait_for_lock(false, r#"{"event":"tab.created"}"#));
        assert!(must_wait_for_lock(true, ""));
        assert!(!must_wait_for_lock(false, r#"{"event":"tab_focused"}"#));
    }
}
