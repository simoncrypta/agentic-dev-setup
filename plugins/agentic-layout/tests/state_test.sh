#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TEST_DIR/.." && pwd)"
PLUGIN_SCRIPT="$PLUGIN_ROOT/layout.sh"
TMP_DIR="$(mktemp -d)"
HERDR_CALL_LOG="$TMP_DIR/herdr-calls.log"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
printf '%s\n' '{"result":{"workspace":{"workspace_id":"misleading-success"}}}'
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"
: >"$HERDR_CALL_LOG"

export HERDR_BIN_PATH="$TMP_DIR/herdr"
export HERDR_CALL_LOG
export HERDR_PLUGIN_ROOT="$PLUGIN_ROOT"
export XDG_STATE_HOME="$TMP_DIR/state-home"
export HOME="$TMP_DIR/home"

# shellcheck disable=SC1090
source "$PLUGIN_SCRIPT"

workspace_id="workspace-valid"
expected_state_dir="$XDG_STATE_HOME/herdr/plugins/agentic-dev.layout"
expected_state_path="$expected_state_dir/$workspace_id.json"
actual_state_path="$(_state_path "$workspace_id")"
[[ "$actual_state_path" == "$expected_state_path" ]] \
  || fail "state path mismatch: $actual_state_path"

cat >"$expected_state_path" <<'JSON'
{
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
}
JSON

loaded="$(_state_load "$workspace_id")" || fail "v3 state should migrate and load"
printf '%s' "$loaded" | jq -e '.version == 4' >/dev/null \
  || fail "migrated state should be version 4"
printf '%s' "$loaded" | jq -e 'has("main_tab_id") | not' >/dev/null \
  || fail "migrated state should drop main_tab_id"
printf '%s' "$loaded" | jq -e '.shell_tab_id == "tab-shell"' >/dev/null \
  || fail "migrated state should keep shell_tab_id"
_state_probe "$workspace_id" || fail "migrated state should probe"

invalid_path="$expected_state_dir/bad.json"
printf '{"version":1,"workspace_id":"bad"}\n' >"$invalid_path"
if _state_probe "bad" >/dev/null 2>&1; then
  fail "invalid state should not probe"
fi
if _state_load "bad" >/dev/null 2>&1; then
  fail "incomplete v1 state should not load"
fi
[[ -f "$expected_state_dir/quarantine/bad.json."* ]] || [[ ! -f "$invalid_path" ]] \
  || fail "invalid state should be quarantined or removed"

printf 'PASS: state schema, v3 migrate, and quarantine\n'
