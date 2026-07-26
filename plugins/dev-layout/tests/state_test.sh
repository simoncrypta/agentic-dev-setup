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

assert_file_empty() {
  local path="$1"
  [[ ! -s "$path" ]] || fail "expected empty file: $path"
}

cat > "$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
printf '%s\n' '{"result":{"workspace":{"workspace_id":"misleading-success"}}}'
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"
: > "$HERDR_CALL_LOG"

export HERDR_BIN_PATH="$TMP_DIR/herdr"
export HERDR_CALL_LOG
export HERDR_PLUGIN_ROOT="$PLUGIN_ROOT"
export XDG_STATE_HOME="$TMP_DIR/state-home"
export HOME="$TMP_DIR/home"

# shellcheck disable=SC1090
source "$PLUGIN_SCRIPT"

workspace_id="workspace-valid"
expected_state_dir="$XDG_STATE_HOME/herdr/plugins/agentic-dev.dev-layout"
expected_state_path="$expected_state_dir/$workspace_id.json"
actual_state_path="$(_state_path "$workspace_id")"
[[ "$actual_state_path" == "$expected_state_path" ]] \
  || fail "state path mismatch: $actual_state_path"
[[ -d "$expected_state_dir" ]] || fail "state path did not create its parent directory"

cat > "$expected_state_path" <<'JSON'
{
  "version": 1,
  "workspace_id": "workspace-valid",
  "label": "valid workspace",
  "workdir": "/tmp/worktree",
  "agent_pane_id": "pane-agent",
  "active_tab": "review",
  "tabs": {
    "review": {"tab_id": "tab-review", "tool_pane_id": "pane-review"}
  }
}
JSON
cp "$expected_state_path" "$TMP_DIR/valid-before.json"

_state_load "$workspace_id" > "$TMP_DIR/valid-loaded.json"
cmp -s "$TMP_DIR/valid-before.json" "$TMP_DIR/valid-loaded.json" \
  || fail "valid state load changed bytes"
cmp -s "$TMP_DIR/valid-before.json" "$expected_state_path" \
  || fail "valid state file changed on disk"
assert_file_empty "$HERDR_CALL_LOG"

printf 'BASELINE PASS: valid state remained byte-identical\n'
printf 'BASELINE PASS: state path is %s\n' "$expected_state_path"
printf 'BASELINE PASS: fake Herdr received zero calls\n'

invalid_failures=0
invalid_cases=0

record_invalid_failure() {
  printf 'INVALID PROBE FAIL: %s\n' "$*" >&2
  invalid_failures=$((invalid_failures + 1))
}

assert_invalid_state() {
  local case_name="$1" invalid_workspace_id="$2" fixture="$3"
  local invalid_path="$expected_state_dir/$invalid_workspace_id.json"
  local loaded status matching=0 quarantined_path
  local -a quarantined_before quarantined_after

  invalid_cases=$((invalid_cases + 1))

  shopt -s nullglob
  quarantined_before=("$expected_state_dir/quarantine/$invalid_workspace_id.json."*)
  shopt -u nullglob

  printf '%s' "$fixture" > "$invalid_path"
  cp "$invalid_path" "$TMP_DIR/$case_name-before.json"

  status=0
  loaded="$(_state_load "$invalid_workspace_id" 2>/dev/null)" || status=$?
  [[ "$status" -ne 0 ]] \
    || record_invalid_failure "$case_name returned success"
  [[ -z "$loaded" ]] \
    || record_invalid_failure "$case_name emitted state on stdout"
  [[ ! -e "$invalid_path" ]] \
    || record_invalid_failure "$case_name remained at the active state path"

  shopt -s nullglob
  quarantined_after=("$expected_state_dir/quarantine/$invalid_workspace_id.json."*)
  shopt -u nullglob
  if [[ "${#quarantined_after[@]}" -ne "$((${#quarantined_before[@]} + 1))" ]]; then
    record_invalid_failure "$case_name did not add exactly one quarantine file"
  fi
  for quarantined_path in "${quarantined_after[@]}"; do
    if cmp -s "$TMP_DIR/$case_name-before.json" "$quarantined_path"; then
      matching=$((matching + 1))
    fi
  done
  if [[ "$matching" -ne 1 ]]; then
    record_invalid_failure "$case_name expected one byte-identical quarantine file, found $matching"
  fi
}

valid_fixture="$(cat "$TMP_DIR/valid-before.json")"
assert_invalid_state malformed workspace-malformed '{'
assert_invalid_state wrong-top-level-shape workspace-array '[]'
assert_invalid_state version-mismatch workspace-version \
  "$(printf '%s' "$valid_fixture" | jq '.workspace_id = "workspace-version" | .version = 2')"
assert_invalid_state workspace-mismatch workspace-expected \
  "$(printf '%s' "$valid_fixture" | jq '.workspace_id = "workspace-other"')"
assert_invalid_state tabs-shape workspace-tabs \
  "$(printf '%s' "$valid_fixture" | jq '.workspace_id = "workspace-tabs" | .tabs = []')"

for field in version workspace_id label workdir agent_pane_id active_tab; do
  assert_invalid_state "missing-$field" "workspace-missing-$field" \
    "$(printf '%s' "$valid_fixture" | jq --arg field "$field" --arg workspace_id "workspace-missing-$field" \
      '.workspace_id = $workspace_id | del(.[$field])')"
done

for field in label workdir agent_pane_id active_tab; do
  assert_invalid_state "non-scalar-$field" "workspace-nonscalar-$field" \
    "$(printf '%s' "$valid_fixture" | jq --arg field "$field" --arg workspace_id "workspace-nonscalar-$field" \
      '.workspace_id = $workspace_id | .[$field] = []')"
done

assert_invalid_state collision-first workspace-collision \
  "$(printf '%s' "$valid_fixture" | jq '.workspace_id = "workspace-collision" | del(.label)')"
assert_invalid_state collision-second workspace-collision \
  "$(printf '%s' "$valid_fixture" | jq '.workspace_id = "workspace-collision" | del(.workdir)')"

stale_path="$expected_state_dir/workspace-stale.json"
printf '%s' "$valid_fixture" \
  | jq '.workspace_id = "workspace-stale" | .agent_pane_id = "missing-pane" | .tabs.review.tab_id = "missing-tab"' \
  > "$stale_path"
cp "$stale_path" "$TMP_DIR/stale-before.json"
_state_probe workspace-stale > "$TMP_DIR/stale-loaded.json"
cmp -s "$TMP_DIR/stale-before.json" "$TMP_DIR/stale-loaded.json" \
  || fail "shape-valid stale state did not load byte-identically"
cmp -s "$TMP_DIR/stale-before.json" "$stale_path" \
  || fail "shape-valid stale state changed on disk"

rm -rf "$expected_state_dir/quarantine"
printf '%s' 'quarantine destination blocker' > "$expected_state_dir/quarantine"
blocked_path="$expected_state_dir/workspace-quarantine-blocked.json"
printf '%s' '{' > "$blocked_path"
blocked_status=0
blocked_output="$(_state_probe workspace-quarantine-blocked 2>/dev/null)" || blocked_status=$?
[[ "$blocked_status" -ne 0 ]] \
  || fail "blocked quarantine probe returned success"
[[ -z "$blocked_output" ]] \
  || fail "blocked quarantine probe emitted state on stdout"
[[ ! -e "$blocked_path" ]] \
  || fail "blocked quarantine left invalid bytes at the active state path"
[[ "$(cat "$expected_state_dir/quarantine")" == 'quarantine destination blocker' ]] \
  || fail "blocked quarantine destination changed"

assert_file_empty "$HERDR_CALL_LOG"

if [[ "$invalid_failures" -ne 0 ]]; then
  printf 'INVALID PROBE RESULT: %d validation assertions failed\n' "$invalid_failures" >&2
  exit 1
fi

printf 'INVALID PROBE PASS: %d malformed/version/workspace/shape records quarantined\n' "$invalid_cases"
printf 'INVALID PROBE PASS: invalid probes emitted no state and returned non-dev\n'
printf 'STALE STATE PASS: shape-valid stale ids remained byte-identical without Herdr calls\n'
printf 'COLLISION PASS: repeated invalid workspace records received distinct quarantine paths\n'
printf 'FAIL-CLOSED PASS: unavailable quarantine destination left no invalid active state\n'
printf 'INVALID PROBE PASS: fake Herdr received zero calls\n'
