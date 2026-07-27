#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TEST_DIR/.." && pwd)"
PLUGIN_SCRIPT="$PLUGIN_ROOT/dev-layout.sh"
TMP_DIR="$(mktemp -d)"
HERDR_CALL_LOG="$TMP_DIR/herdr-calls.log"

cleanup() {
  rm -rf "$TMP_DIR"
  printf 'CLEANUP PASS: removed temporary state and fake Herdr: %s\n' "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_no_mutation_calls() {
  local context="$1"
  if grep -qE '^(workspace (create|rename|focus)|tab (create|rename|focus)|pane (split|move|swap|run|focus)|agent focus)' \
    "$HERDR_CALL_LOG"; then
    printf '%s\n' "unexpected mutating calls:" >&2
    cat "$HERDR_CALL_LOG" >&2
    fail "$context invoked Herdr mutation outside dev state"
  fi
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

FAKE_WORKSPACES_FILE="$TMP_DIR/workspaces.json"
FAKE_TABS_FILE="$TMP_DIR/tabs.json"
FAKE_PANES_FILE="$TMP_DIR/panes.json"

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
    cat "$FAKE_WORKSPACES_FILE"
    ;;
  tab)
    case "${2:-}" in
      list) cat "$FAKE_TABS_FILE" ;;
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
        if [[ "$pane" == "${FAKE_AGENT_PANE:-pane-agent}" ]]; then
          jq -n --arg pane "$pane" --arg tab "${FAKE_AGENT_TAB:-tab-review}" \
            '{result:{pane:{pane_id:$pane,tab_id:$tab}}}'
        else
          jq -n --arg pane "$pane" '{result:{pane:{pane_id:$pane,tab_id:""}}}'
        fi
        ;;
      list)
        cat "$FAKE_PANES_FILE"
        ;;
      *) exit 0 ;;
    esac
    ;;
  agent)
    exit 0
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
export FAKE_WORKSPACES_FILE FAKE_TABS_FILE FAKE_PANES_FILE

# shellcheck disable=SC1090
source "$PLUGIN_SCRIPT"

state_dir="$XDG_STATE_HOME/herdr/plugins/agentic-dev.dev-layout"

reset_case() {
  rm -rf "$state_dir"
  : > "$HERDR_CALL_LOG"
  unset HERDR_WORKSPACE_ID WT_HERDR_LABEL WT_HERDR_WORKDIR || true
  write_fixture "$FAKE_WORKSPACES_FILE" '{result:{workspaces:[]}}'
  write_fixture "$FAKE_TABS_FILE" '{result:{tabs:[]}}'
  write_fixture "$FAKE_PANES_FILE" '{result:{panes:[]}}'
  export FAKE_AGENT_PANE="pane-agent"
  export FAKE_AGENT_TAB="tab-review"
  unset FAKE_DEAD_PANES || true
}

seed_dev_state() {
  mkdir -p "$state_dir"
  cat > "$state_dir/ws-dev.json" <<'JSON'
{
  "version": 1,
  "workspace_id": "ws-dev",
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
  export HERDR_WORKSPACE_ID="ws-dev"
}

run_action() {
  local rc=0
  main "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

# --- prefix actions outside dev state: successful no-op, zero mutation ---
reset_case
export HERDR_WORKSPACE_ID="ws-plain"
for action in select_review select_explorer select_terminal focus_agent; do
  rc="$(run_action "$action")"
  [[ "$rc" == "0" ]] || fail "non-dev $action exited $rc"
done
assert_no_mutation_calls "prefix actions in plain workspace"
[[ ! -e "$state_dir/ws-plain.json" ]] || fail "prefix navigation created a state record"
printf 'PASS: prefix actions no-op outside dev state with zero Herdr mutation\n'

# --- alt fallback: 1-tab workspace focuses index 1, higher indices no-op ---
reset_case
export HERDR_WORKSPACE_ID="ws-plain"
write_fixture "$FAKE_TABS_FILE" '{result:{tabs:[{tab_id:"tab-one"}]}}'
rc="$(run_action alt_review)"
[[ "$rc" == "0" ]] || fail "alt_review exited $rc"
assert_call_count '^tab focus tab-one$' 1 "alt_review focused the first tab"
assert_call_count '^(tab create|workspace create|pane split|pane run)' 0 "alt fallback created layout pieces"
: > "$HERDR_CALL_LOG"
rc="$(run_action alt_explorer)"
[[ "$rc" == "0" ]] || fail "out-of-range alt_explorer exited $rc"
assert_call_count '^tab focus' 0 "out-of-range alt_explorer focused a tab"
rc="$(run_action alt_terminal)"
[[ "$rc" == "0" ]] || fail "out-of-range alt_terminal exited $rc"
assert_call_count '^tab focus' 0 "out-of-range alt_terminal focused a tab"
printf 'PASS: alt fallback focuses index 1 and no-ops out-of-range on a 1-tab workspace\n'

# --- alt fallback: 2-tab workspace focuses index 2, index 3 no-op ---
reset_case
export HERDR_WORKSPACE_ID="ws-plain"
write_fixture "$FAKE_TABS_FILE" '{result:{tabs:[{tab_id:"tab-one"},{tab_id:"tab-two"}]}}'
rc="$(run_action alt_explorer)"
[[ "$rc" == "0" ]] || fail "alt_explorer exited $rc"
assert_call_count '^tab focus tab-two$' 1 "alt_explorer focused the second tab"
: > "$HERDR_CALL_LOG"
rc="$(run_action alt_terminal)"
[[ "$rc" == "0" ]] || fail "out-of-range alt_terminal exited $rc"
assert_call_count '^tab focus' 0 "out-of-range alt_terminal focused a tab on a 2-tab workspace"
printf 'PASS: alt fallback focuses index 2 and no-ops index 3 on a 2-tab workspace\n'

# --- alt fallback: 3-tab workspace focuses index 3 ---
reset_case
export HERDR_WORKSPACE_ID="ws-plain"
write_fixture "$FAKE_TABS_FILE" \
  '{result:{tabs:[{tab_id:"tab-one"},{tab_id:"tab-two"},{tab_id:"tab-three"}]}}'
rc="$(run_action alt_terminal)"
[[ "$rc" == "0" ]] || fail "alt_terminal exited $rc"
assert_call_count '^tab focus tab-three$' 1 "alt_terminal focused the third tab"
printf 'PASS: alt fallback focuses index 3 on a 3-tab workspace\n'

# --- dev workspace: semantic selection moves agent once, creates nothing ---
reset_case
seed_dev_state
rc="$(run_action select_explorer)"
[[ "$rc" == "0" ]] || fail "dev select_explorer exited $rc"
assert_call_count '^tab focus tab-explorer$' 1 "dev select_explorer focused explorer tab"
assert_call_count '^pane move pane-agent' 1 "dev select_explorer moved the agent pane once"
assert_call_count '^(tab create|workspace create|pane split|pane run|workspace rename|tab rename)' 0 \
  "dev navigation created layout pieces"
active_tab="$(jq -r '.active_tab' "$state_dir/ws-dev.json")"
[[ "$active_tab" == "explorer" ]] || fail "dev select_explorer recorded active_tab=$active_tab"
printf 'PASS: dev workspace keeps semantic tab selection with one agent move\n'

# --- dev workspace: focus_agent focuses the live agent, creates nothing ---
reset_case
seed_dev_state
rc="$(run_action focus_agent)"
[[ "$rc" == "0" ]] || fail "dev focus_agent exited $rc"
assert_call_count '^agent focus pane-agent$' 1 "dev focus_agent focused the agent"
assert_call_count '^(tab create|workspace create|pane split|pane run)' 0 \
  "dev focus_agent created layout pieces"
printf 'PASS: dev focus_agent focuses the live agent without layout mutation\n'

# --- dev workspace: alt actions keep semantic meaning ---
reset_case
seed_dev_state
rc="$(run_action alt_explorer)"
[[ "$rc" == "0" ]] || fail "dev alt_explorer exited $rc"
assert_call_count '^tab focus tab-explorer$' 1 "dev alt_explorer kept semantic explorer selection"
assert_call_count '^tab focus tab-two$' 0 "dev alt_explorer used indexed fallback"
printf 'PASS: dev workspace alt actions select semantic tabs, not indices\n'

printf 'ALL PASS: navigation gating and alt fallback matrix\n'
