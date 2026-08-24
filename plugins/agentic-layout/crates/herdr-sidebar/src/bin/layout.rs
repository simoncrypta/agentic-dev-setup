//! Layout sidecar: pure JSON decisions in-process; unmatched verbs exec layout.sh.
//!
//! Dock/save must drop the layout lock before `tab focus` — `tab.focused` can
//! dispatch synchronously, and holding the lock across that RPC deadlocks.
//! Activation still lives in layout.sh; this binary only plans or shims.

use std::env;
use std::io::{self, Read};
use std::path::PathBuf;
use std::process::Command;

use herdr_sidebar::herdr_json::{LayoutState, Tab, parse_tab_list};
use herdr_sidebar::layout_plan::{
    AGENT_RATIO, SIDEBAR_RATIO, adopt_tabs_with_shell, dock_plan, geometry, select_tab_number,
    select_tab_relative,
};

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("--adopt-tabs") => exit_json(cmd_adopt_tabs()),
        Some("--dock-plan") => {
            let tab_id = args.get(1).cloned().unwrap_or_default();
            exit_json(cmd_dock_plan(&tab_id));
        }
        Some("--migrate-state") => {
            let workspace_id = args
                .get(1)
                .cloned()
                .or_else(|| env::var("HERDR_WORKSPACE_ID").ok())
                .unwrap_or_default();
            exit_json(cmd_migrate_state(&workspace_id));
        }
        Some("--tab-index") => {
            let n = parse_i32(args.get(1)).unwrap_or(1);
            exit_id(cmd_select_tab(n));
        }
        Some("--tab-relative") => {
            let delta = parse_i32(args.get(1)).unwrap_or(1);
            exit_id(cmd_select_relative(delta));
        }
        Some("--split-ratios") => exit_json(cmd_split_ratios()),
        Some("--help" | "-h") => {
            eprintln!(
                "usage: herdr-layout --adopt-tabs | --dock-plan [tab_id] | --migrate-state [workspace_id] | --tab-index N | --tab-relative N | --split-ratios | <layout.sh verb>"
            );
            std::process::exit(0);
        }
        Some(_) | None => shim(&args),
    }
}

fn parse_i32(arg: Option<&String>) -> Option<i32> {
    arg.and_then(|s| s.parse().ok())
}

fn read_stdin() -> String {
    let mut buf = String::new();
    let _ = io::stdin().read_to_string(&mut buf);
    buf
}

fn cmd_adopt_tabs() -> Result<String, String> {
    let raw: serde_json::Value =
        serde_json::from_str(&read_stdin()).map_err(|e| format!("invalid json: {e}"))?;
    let state = LayoutState::ingest(
        "",
        raw.get("state").cloned().unwrap_or(serde_json::json!({})),
    )
    .ok_or_else(|| "invalid state".to_string())?;
    let tabs = tabs_from_value(raw.get("tabs").cloned())?;
    let shell_override = raw.get("shell_tab_id").and_then(|v| v.as_str());
    let adopted = adopt_tabs_with_shell(&state, &tabs, shell_override);
    serde_json::to_string(&adopted).map_err(|e| e.to_string())
}

fn ratio_from(raw: &serde_json::Value, key: &str, default: f64) -> f64 {
    raw.get(key).and_then(|v| v.as_f64()).unwrap_or(default)
}

fn cmd_split_ratios() -> Result<String, String> {
    let buf = read_stdin();
    let raw: serde_json::Value = if buf.trim().is_empty() {
        serde_json::json!({})
    } else {
        serde_json::from_str(&buf).map_err(|e| format!("invalid json: {e}"))?
    };
    let geo = geometry(
        ratio_from(&raw, "agent_ratio", AGENT_RATIO),
        ratio_from(&raw, "sidebar_ratio", SIDEBAR_RATIO),
    );
    serde_json::to_string(&geo).map_err(|e| e.to_string())
}

fn cmd_dock_plan(tab_id_arg: &str) -> Result<String, String> {
    let raw: serde_json::Value =
        serde_json::from_str(&read_stdin()).map_err(|e| format!("invalid json: {e}"))?;
    let state = LayoutState::ingest(
        "",
        raw.get("state")
            .cloned()
            .ok_or_else(|| "missing state".to_string())?,
    )
    .ok_or_else(|| "invalid state".to_string())?;
    let tab_id = if tab_id_arg.is_empty() {
        raw.get("tab_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    } else {
        tab_id_arg.to_string()
    };
    let plan = dock_plan(
        &state,
        &tab_id,
        ratio_from(&raw, "agent_ratio", AGENT_RATIO),
        ratio_from(&raw, "sidebar_ratio", SIDEBAR_RATIO),
    )
    .ok_or_else(|| "no dock plan for tab".to_string())?;
    serde_json::to_string(&plan).map_err(|e| e.to_string())
}

fn cmd_migrate_state(workspace_id: &str) -> Result<String, String> {
    let json = read_stdin();
    let state = LayoutState::ingest_json(workspace_id, &json)
        .ok_or_else(|| "could not migrate state".to_string())?;
    serde_json::to_string(&state).map_err(|e| e.to_string())
}

fn cmd_select_tab(n: i32) -> Result<String, String> {
    let tabs = tabs_from_stdin()?;
    select_tab_number(&tabs, n.max(0) as u32).ok_or_else(|| "no tab at that index".into())
}

fn cmd_select_relative(delta: i32) -> Result<String, String> {
    let tabs = tabs_from_stdin()?;
    select_tab_relative(&tabs, delta).ok_or_else(|| "no tabs".into())
}

fn tabs_from_stdin() -> Result<Vec<Tab>, String> {
    tabs_from_value(Some(
        serde_json::from_str(&read_stdin()).map_err(|e| format!("invalid json: {e}"))?,
    ))
}

fn tabs_from_value(value: Option<serde_json::Value>) -> Result<Vec<Tab>, String> {
    let Some(value) = value else {
        return Ok(Vec::new());
    };
    if let Ok(tabs) = serde_json::from_value::<Vec<Tab>>(value.clone()) {
        return Ok(tabs);
    }
    Ok(parse_tab_list(&value.to_string()))
}

fn exit_json(result: Result<String, String>) {
    match result {
        Ok(json) => println!("{json}"),
        Err(err) => {
            eprintln!("herdr-layout: {err}");
            std::process::exit(1);
        }
    }
}

fn exit_id(result: Result<String, String>) {
    match result {
        Ok(id) => println!("{id}"),
        Err(err) => {
            eprintln!("herdr-layout: {err}");
            std::process::exit(1);
        }
    }
}

fn layout_sh_path() -> PathBuf {
    if let Ok(root) = env::var("HERDR_PLUGIN_ROOT") {
        let path = PathBuf::from(root).join("layout.sh");
        if path.is_file() {
            return path;
        }
    }
    if let Ok(cwd) = env::current_dir() {
        let path = cwd.join("layout.sh");
        if path.is_file() {
            return path;
        }
    }
    if let Ok(exe) = env::current_exe()
        && let Some(root) = exe
            .parent()
            .and_then(|p| p.parent())
            .and_then(|p| p.parent())
    {
        let path = root.join("layout.sh");
        if path.is_file() {
            return path;
        }
    }
    PathBuf::from("layout.sh")
}

fn shim(args: &[String]) -> ! {
    let script = layout_sh_path();
    let mut cmd = Command::new("bash");
    cmd.arg(&script).args(args);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let err = cmd.exec();
        eprintln!("herdr-layout: failed to exec {}: {err}", script.display());
        std::process::exit(127);
    }
    #[cfg(not(unix))]
    {
        match cmd.status() {
            Ok(status) => std::process::exit(status.code().unwrap_or(1)),
            Err(err) => {
                eprintln!("herdr-layout: failed to exec {}: {err}", script.display());
                std::process::exit(127);
            }
        }
    }
}
