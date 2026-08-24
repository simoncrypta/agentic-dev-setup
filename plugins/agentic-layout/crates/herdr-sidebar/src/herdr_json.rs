//! Shared Herdr JSON envelopes used by layout decisions.
//!
//! `launch.rs` keeps its own pane-list structs until a later tidy. These types
//! are the ones `layout_plan` actually consumes: tab lists and layout state.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

pub const STATE_VERSION: u32 = 4;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tab {
    pub tab_id: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub focused: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
struct TabListResult {
    #[serde(default)]
    tabs: Vec<Tab>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
struct TabListMsg {
    #[serde(default)]
    result: TabListResult,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditorEntry {
    #[serde(default)]
    pub tab_id: String,
    #[serde(default)]
    pub pane_id: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LayoutState {
    #[serde(default)]
    pub version: u32,
    #[serde(default)]
    pub workspace_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub workdir: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub shell_tab_id: String,
    #[serde(default)]
    pub review_tab_id: String,
    #[serde(default)]
    pub agent_pane_id: String,
    #[serde(default)]
    pub review_pane_id: String,
    #[serde(default)]
    pub shell_pane_id: String,
    #[serde(default)]
    pub sidebar_pane_id: String,
    #[serde(default = "default_center_view")]
    pub active_center_view: String,
    #[serde(default = "default_sidebar_view")]
    pub active_sidebar_view: String,
    #[serde(default)]
    pub editors: BTreeMap<String, EditorEntry>,
    /// Present only on pre-v4 documents; never written back.
    #[serde(default, skip_serializing)]
    pub main_tab_id: Option<String>,
}

fn default_center_view() -> String {
    "shell".into()
}

fn default_sidebar_view() -> String {
    "files".into()
}

impl LayoutState {
    pub fn init(workspace_id: impl Into<String>, workdir: impl Into<String>) -> Self {
        Self {
            version: STATE_VERSION,
            workspace_id: workspace_id.into(),
            workdir: workdir.into(),
            label: String::new(),
            shell_tab_id: String::new(),
            review_tab_id: String::new(),
            agent_pane_id: String::new(),
            review_pane_id: String::new(),
            shell_pane_id: String::new(),
            sidebar_pane_id: String::new(),
            active_center_view: default_center_view(),
            active_sidebar_view: default_sidebar_view(),
            editors: BTreeMap::new(),
            main_tab_id: None,
        }
    }

    pub fn is_schema_ok(&self) -> bool {
        self.version == STATE_VERSION && self.main_tab_id.is_none()
    }

    /// Deserialize wire JSON and normalize to v4. One ingest path: serde, then
    /// bump version, drop `main_tab_id`, and clear panes when `version < 3`.
    pub fn ingest(workspace_id: &str, raw: serde_json::Value) -> Option<Self> {
        let raw = if raw.is_array() {
            raw.as_array()?.first()?.clone()
        } else {
            raw
        };
        if !raw.is_object() {
            return None;
        }
        let version = raw.get("version").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
        let mut state: Self = serde_json::from_value(raw).ok()?;
        if version < 3 {
            state.agent_pane_id.clear();
            state.review_pane_id.clear();
            state.shell_pane_id.clear();
            state.sidebar_pane_id.clear();
            if !workspace_id.is_empty() {
                state.workspace_id = workspace_id.to_string();
            }
        } else if state.workspace_id.is_empty() {
            state.workspace_id = workspace_id.to_string();
        }
        state.version = STATE_VERSION;
        state.main_tab_id = None;
        Some(state)
    }

    pub fn ingest_json(workspace_id: &str, json: &str) -> Option<Self> {
        Self::ingest(workspace_id, serde_json::from_str(json).ok()?)
    }
}

pub fn parse_tab_list(json: &str) -> Vec<Tab> {
    let value: serde_json::Value = match serde_json::from_str(json) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };
    match value {
        serde_json::Value::Array(_) => serde_json::from_value(value).unwrap_or_default(),
        other => serde_json::from_value::<TabListMsg>(other)
            .map(|m| m.result.tabs)
            .unwrap_or_default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_tab_list_reads_result_envelope() {
        let json = r#"{"result":{"tabs":[{"tab_id":"w1:t1","label":"Shell","focused":true}]}}"#;
        let tabs = parse_tab_list(json);
        assert_eq!(tabs.len(), 1);
        assert_eq!(tabs[0].tab_id, "w1:t1");
        assert!(tabs[0].focused);
    }

    #[test]
    fn parse_tab_list_reads_a_bare_array() {
        let tabs = parse_tab_list(r#"[{"tab_id":"w1:t1","label":"Shell"}]"#);
        assert_eq!(tabs[0].tab_id, "w1:t1");
    }

    #[test]
    fn v3_ingest_drops_main_tab_id_and_keeps_panes() {
        let raw = serde_json::json!({
            "version": 3,
            "workspace_id": "workspace-valid",
            "label": "valid",
            "workdir": "/tmp/worktree",
            "main_tab_id": "tab-review",
            "review_tab_id": "tab-review",
            "shell_tab_id": "tab-shell",
            "agent_pane_id": "pane-agent",
            "review_pane_id": "pane-review",
            "shell_pane_id": "pane-shell",
            "sidebar_pane_id": "pane-sidebar",
            "active_center_view": "review",
            "active_sidebar_view": "files",
            "editors": {}
        });
        let state = LayoutState::ingest("workspace-valid", raw).expect("ingest");
        assert_eq!(state.version, 4);
        assert!(state.main_tab_id.is_none());
        assert!(state.is_schema_ok());
        assert_eq!(state.shell_tab_id, "tab-shell");
        assert_eq!(state.agent_pane_id, "pane-agent");
        let encoded = serde_json::to_value(&state).unwrap();
        assert!(encoded.get("main_tab_id").is_none());
    }

    #[test]
    fn pre_v3_ingest_clears_pane_ids() {
        let raw = serde_json::json!({
            "version": 2,
            "workspace_id": "w",
            "workdir": "/tmp",
            "shell_tab_id": "t",
            "agent_pane_id": "stale"
        });
        let state = LayoutState::ingest("w", raw).expect("ingest");
        assert_eq!(state.version, 4);
        assert!(state.agent_pane_id.is_empty());
        assert_eq!(state.shell_tab_id, "t");
    }
}
