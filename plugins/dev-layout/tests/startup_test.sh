#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TEST_DIR/.." && pwd)"
PLUGIN_SCRIPT="$PLUGIN_ROOT/dev-layout.sh"
MANIFEST="$PLUGIN_ROOT/herdr-plugin.toml"
TMP_DIR="$(mktemp -d)"
HERDR_CALL_LOG="$TMP_DIR/herdr-calls.log"
FAKE_WORKSPACES_FILE="$TMP_DIR/workspaces.json"
FAKE_PANES_FILE="$TMP_DIR/panes.json"

cleanup() {
  rm -rf "$TMP_DIR"
  printf 'CLEANUP PASS: removed temporary state and fake Herdr: %s\n' "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [[ "$actual" == "$expected" ]] || fail "$message (expected=$expected actual=$actual)"
}

assert_call_count() {
  local pattern="$1" expected="$2" context="$3"
  local actual
  actual="$(grep -cE "$pattern" "$HERDR_CALL_LOG" || true)"
  [[ "$actual" == "$expected" ]] || {
    cat "$HERDR_CALL_LOG" >&2
    fail "$context (pattern '$pattern' expected $expected, got $actual)"
  }
}

assert_no_create_focus() {
  local context="$1"
  if grep -qE '^(workspace (create|rename|focus)|tab (create|rename|focus)|pane (split|move|swap|run|focus)|agent focus)' \
    "$HERDR_CALL_LOG"; then
    printf '%s\n' "unexpected mutating calls:" >&2
    cat "$HERDR_CALL_LOG" >&2
    fail "$context invoked layout-creating or focusing Herdr calls"
  fi
}

write_fixture() {
  local path="$1"
  shift
  jq -n "$@" >"$path"
}

mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "${1:-}" in
  workspace)
    case "${2:-}" in
      list) cat "$FAKE_WORKSPACES_FILE" ;;
      *) exit 0 ;;
    esac
    ;;
  pane)
    case "${2:-}" in
      get)
        pane="${3:-}"
        if [[ " ${FAKE_DEAD_PANES:-} " == *" $pane "* ]]; then
          exit 1
        fi
        jq -n --arg pane "$pane" '{result:{pane:{pane_id:$pane}}}'
        ;;
      list)
        cat "$FAKE_PANES_FILE"
        ;;
      *) exit 0 ;;
    esac
    ;;
  *)
    printf '%s\n' '{"result":{"misleading":"success"}}'
    ;;
esac
FAKE_HERDR
chmod +x "$TMP_DIR/bin/herdr"

export HERDR_BIN_PATH="$TMP_DIR/bin/herdr"
export HERDR_CALL_LOG
export HERDR_PLUGIN_ROOT="$PLUGIN_ROOT"
export XDG_STATE_HOME="$TMP_DIR/state-home"
export HOME="$TMP_DIR/home"
export FAKE_WORKSPACES_FILE FAKE_PANES_FILE

# shellcheck disable=SC1090
source "$PLUGIN_SCRIPT"

state_dir="$XDG_STATE_HOME/herdr/plugins/agentic-dev.dev-layout"

reset_case() {
  rm -rf "$state_dir"
  mkdir -p "$state_dir"
  : > "$HERDR_CALL_LOG"
  write_fixture "$FAKE_WORKSPACES_FILE" '{result:{workspaces:[]}}'
  write_fixture "$FAKE_PANES_FILE" '{result:{panes:[]}}'
  unset FAKE_DEAD_PANES || true
}

seed_valid_state() {
  local workspace_id="$1"
  cat > "$state_dir/$workspace_id.json" <<JSON
{
  "version": 1,
  "workspace_id": "$workspace_id",
  "label": "dev workspace",
  "workdir": "/tmp/worktree",
  "agent_pane_id": "pane-agent",
  "active_tab": "review",
  "tabs": {
    "review": {"tab_id": "tab-review", "tool_pane_id": "pane-review"},
    "explorer": {"tab_id": "tab-explorer", "tool_pane_id": "pane-explorer"},
    "terminal": {"tab_id": "tab-terminal", "tool_pane_id": "pane-terminal"}
  }
}
JSON
}

# --- Manifest contract: version, floor, startup, Alt actions ---
python3 - <<'PY' "$MANIFEST"
import sys
import tomllib
from pathlib import Path

with Path(sys.argv[1]).open("rb") as handle:
    manifest = tomllib.load(handle)
assert manifest["id"] == "agentic-dev.dev-layout", manifest["id"]
assert manifest["version"] == "0.2.0", manifest["version"]
assert manifest["min_herdr_version"] == "0.7.5", manifest["min_herdr_version"]
assert "startup" in manifest and len(manifest["startup"]) >= 1, manifest.get("startup")
assert manifest["startup"][0]["command"] == ["bash", "dev-layout.sh", "startup"], manifest["startup"][0]
action_ids = {a["id"] for a in manifest["actions"]}
for required in (
    "alt_review",
    "alt_explorer",
    "alt_terminal",
    "select_review",
    "focus_agent",
    "create",
    "apply",
):
    assert required in action_ids, required
print("MANIFEST CONTRACT PASS: id/version/min/startup/alt actions")
PY

# --- Happy: live workspace with one dead pane keeps metadata, clears only dead id ---
reset_case
seed_valid_state "ws-live"
cp "$state_dir/ws-live.json" "$TMP_DIR/ws-live-before.json"
write_fixture "$FAKE_WORKSPACES_FILE" \
  '{result:{workspaces:[{workspace_id:"ws-live",label:"dev workspace",focused:true}]}}'
export FAKE_DEAD_PANES="pane-explorer"
rc=0
main startup >/dev/null 2>&1 || rc=$?
[[ "$rc" == "0" ]] || fail "startup exited $rc"
assert_no_create_focus "live-state startup"
[[ -f "$state_dir/ws-live.json" ]] || fail "live state record was deleted"
label="$(jq -r '.label' "$state_dir/ws-live.json")"
workdir="$(jq -r '.workdir' "$state_dir/ws-live.json")"
active_tab="$(jq -r '.active_tab' "$state_dir/ws-live.json")"
agent="$(jq -r '.agent_pane_id' "$state_dir/ws-live.json")"
review_tool="$(jq -r '.tabs.review.tool_pane_id' "$state_dir/ws-live.json")"
explorer_tool="$(jq -r '.tabs.explorer.tool_pane_id' "$state_dir/ws-live.json")"
terminal_tool="$(jq -r '.tabs.terminal.tool_pane_id' "$state_dir/ws-live.json")"
review_tab="$(jq -r '.tabs.review.tab_id' "$state_dir/ws-live.json")"
assert_eq "dev workspace" "$label" "label preserved"
assert_eq "/tmp/worktree" "$workdir" "workdir preserved"
assert_eq "review" "$active_tab" "active_tab preserved"
assert_eq "pane-agent" "$agent" "live agent pane preserved"
assert_eq "pane-review" "$review_tool" "live review tool pane preserved"
assert_eq "" "$explorer_tool" "dead explorer tool pane cleared"
assert_eq "pane-terminal" "$terminal_tool" "live terminal tool pane preserved"
assert_eq "tab-review" "$review_tab" "tab ids preserved"
assert_call_count '^workspace create' 0 "startup created a workspace"
assert_call_count '^tab create' 0 "startup created a tab"
printf 'PASS: live valid state clears only the dead pane id and retains metadata\n'

# --- Closed workspace: delete state, create nothing ---
reset_case
seed_valid_state "ws-closed"
write_fixture "$FAKE_WORKSPACES_FILE" '{result:{workspaces:[]}}'
rc=0
main startup >/dev/null 2>&1 || rc=$?
[[ "$rc" == "0" ]] || fail "closed-workspace startup exited $rc"
[[ ! -e "$state_dir/ws-closed.json" ]] || fail "closed workspace state remained"
assert_no_create_focus "closed-workspace startup"
printf 'PASS: closed-workspace state is deleted without creating layout\n'

# --- Malformed state: quarantine, create nothing ---
reset_case
printf '{not-json' > "$state_dir/ws-bad.json"
rc=0
main startup >/dev/null 2>&1 || rc=$?
[[ "$rc" == "0" ]] || fail "malformed-state startup exited $rc"
[[ ! -e "$state_dir/ws-bad.json" ]] || fail "malformed state remained active"
shopt -s nullglob
quarantined=("$state_dir/quarantine/ws-bad.json."*)
shopt -u nullglob
[[ "${#quarantined[@]}" -eq 1 ]] || fail "malformed state was not quarantined"
assert_no_create_focus "malformed-state startup"
printf 'PASS: malformed state quarantines without layout creation\n'

# --- Workspace list failure: preserve state (fail closed) ---
reset_case
seed_valid_state "ws-unknown"
cp "$state_dir/ws-unknown.json" "$TMP_DIR/ws-unknown-before.json"
cat > "$TMP_DIR/bin/herdr" <<'FAKE_HERDR_FAIL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "${1:-}" in
  workspace)
    exit 1
    ;;
  pane)
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
FAKE_HERDR_FAIL
chmod +x "$TMP_DIR/bin/herdr"
rc=0
main startup >/dev/null 2>&1 || rc=$?
[[ "$rc" == "0" ]] || fail "list-failure startup exited $rc"
cmp -s "$TMP_DIR/ws-unknown-before.json" "$state_dir/ws-unknown.json" \
  || fail "list-failure startup mutated preserved state"
printf 'PASS: workspace list failure preserves state without mutation\n'

printf 'ALL PASS: startup reconciliation matrix\n'
