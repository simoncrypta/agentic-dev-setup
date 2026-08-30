#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TEST_DIR/.." && pwd)"
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

write_herdr() {
  cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "$1 $2" in
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"Shell","focused":true}]}}'
    ;;
  "tab create")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t2"}}}'
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"pane-shell","tab_id":"w1:t1"},{"pane_id":"pane-agent","tab_id":"w1:t1"},{"pane_id":"pane-sidebar","tab_id":"w1:t1"},{"pane_id":"pane-review","tab_id":"w1:t2"}]}}'
    ;;
  "pane get")
    id="${3:-}"
    tab="w1:t1"
    [[ "$id" == pane-review ]] && tab="w1:t2"
    agent="null"
    [[ "$id" == pane-agent ]] && agent='"live"'
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","agent":%s}}}\n' "$id" "$tab" "$agent"
    ;;
  "pane current")
    printf '%s\n' '{"result":{"pane":{"pane_id":"pane-review","tab_id":"w1:t2"}}}'
    ;;
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","focused":true}]}}'
    ;;
  *)
    printf '%s\n' '{"result":{}}'
    ;;
esac
FAKE_HERDR
  chmod +x "$TMP_DIR/herdr"
}

export HERDR_BIN_PATH="$TMP_DIR/herdr"
export HERDR_CALL_LOG
export HERDR_PLUGIN_ROOT="$PLUGIN_ROOT"
export XDG_STATE_HOME="$TMP_DIR/state-home"
export HOME="$TMP_DIR/home"
write_herdr
: >"$HERDR_CALL_LOG"

# shellcheck disable=SC1090
source "$PLUGIN_ROOT/layout.sh"

mkdir -p "$(_state_dir)"
cat >"$(_state_path w1)" <<'JSON'
{
  "version": 4,
  "workspace_id": "w1",
  "workdir": "/tmp/worktree",
  "label": "w1",
  "shell_tab_id": "w1:t1",
  "review_tab_id": "",
  "agent_pane_id": "pane-agent",
  "review_pane_id": "",
  "shell_pane_id": "pane-shell",
  "sidebar_pane_id": "pane-sidebar",
  "active_center_view": "shell",
  "active_sidebar_view": "files",
  "editors": {}
}
JSON

export HERDR_WORKSPACE_ID=w1
state="$(cat "$(_state_path w1)")"
tabs="$(_ensure_shell_and_review_tabs w1 /tmp/worktree "$state")"
review_id="${tabs#*$'\t'}"
[[ -z "$review_id" ]] || fail "ensure should not create a Review tab, got '$review_id'"
grep -q 'tab create' "$HERDR_CALL_LOG" && fail "ensure must not tab-create Review"
printf 'PASS: layout ensure does not create a Review tab\n'

: >"$HERDR_CALL_LOG"
_open_review || fail "open-review should succeed"
got="$(jq -r '.review_tab_id' "$(_state_path w1)")"
[[ "$got" == "w1:t2" ]] || fail "open-review should persist review_tab_id, got $got"
got="$(jq -r '.review_pane_id' "$(_state_path w1)")"
[[ "$got" == "pane-review" ]] || fail "open-review should persist review_pane_id, got $got"
grep -q 'tab create' "$HERDR_CALL_LOG" || fail "open-review should create the Review tab"
grep -qE 'hunk(\\ | )diff(\\ | )--watch' "$HERDR_CALL_LOG" \
  || fail "open-review should launch hunk diff --watch; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: select-review / open-review creates Review and launches hunk --watch\n'

# After open, fake herdr must report the Review tab as live so close can find it.
cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "$1 $2" in
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"Shell","focused":false},{"tab_id":"w1:t2","label":"Review","focused":true}]}}'
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"pane-shell","tab_id":"w1:t1"},{"pane_id":"pane-agent","tab_id":"w1:t2"},{"pane_id":"pane-sidebar","tab_id":"w1:t2"},{"pane_id":"pane-review","tab_id":"w1:t2"}]}}'
    ;;
  "pane get")
    id="${3:-}"
    tab="w1:t2"
    [[ "$id" == pane-shell ]] && tab="w1:t1"
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s"}}}\n' "$id" "$tab"
    ;;
  "pane layout")
    printf '%s\n' '{"result":{"layout":{"splits":[],"panes":[]}}}'
    ;;
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","focused":true}]}}'
    ;;
  *)
    printf '%s\n' '{"result":{}}'
    ;;
esac
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"
: >"$HERDR_CALL_LOG"
_close_review
got="$(jq -r '.review_tab_id' "$(_state_path w1)")"
[[ "$got" == "" ]] || fail "close-review should clear review_tab_id, got $got"
got="$(jq -r '.review_pane_id' "$(_state_path w1)")"
[[ "$got" == "" ]] || fail "close-review should clear review_pane_id, got $got"
got="$(jq -r '.active_center_view' "$(_state_path w1)")"
[[ "$got" == "shell" ]] || fail "close-review should land on shell, got $got"
grep -q 'tab close w1:t2' "$HERDR_CALL_LOG" || fail "close-review should close the Review tab"
printf 'PASS: close-review docks to Shell and clears review ids\n'

# pane.exited on the review center closes the Review tab.
cat >"$(_state_path w1)" <<'JSON'
{
  "version": 4,
  "workspace_id": "w1",
  "workdir": "/tmp/worktree",
  "label": "w1",
  "shell_tab_id": "w1:t1",
  "review_tab_id": "w1:t2",
  "agent_pane_id": "pane-agent",
  "review_pane_id": "pane-review",
  "shell_pane_id": "pane-shell",
  "sidebar_pane_id": "pane-sidebar",
  "active_center_view": "review",
  "active_sidebar_view": "files",
  "editors": {}
}
JSON
: >"$HERDR_CALL_LOG"
_on_pane_exited pane-review
got="$(jq -r '.review_tab_id' "$(_state_path w1)")"
[[ "$got" == "" ]] || fail "review pane exit should clear review_tab_id, got $got"
grep -q 'tab close w1:t2' "$HERDR_CALL_LOG" || fail "review pane exit should close the Review tab"
printf 'PASS: review pane exit closes the Review tab\n'
