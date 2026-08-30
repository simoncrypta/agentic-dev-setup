#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

SCRIPT="$ROOT/skills/review/scripts/wait-comments.sh"
export WAIT_COMMENTS_POLL_SECONDS=0
export HUNK_BIN="$TMP_DIR/hunk"

write_hunk() {
  cat >"$HUNK_BIN" <<FAKE
#!/usr/bin/env bash
set -euo pipefail
state_file="$TMP_DIR/hunk-state"
action="\$*"
if [[ "\$action" != *"comment list"* ]]; then
  echo "unexpected: \$action" >&2
  exit 1
fi
if [[ ! -f "\$state_file" ]]; then
  echo "No active Hunk sessions" >&2
  exit 1
fi
cat "\$state_file"
FAKE
  chmod +x "$HUNK_BIN"
}

write_hunk

# No session → 2
set +e
"$SCRIPT" --repo . --timeout 1 >/dev/null
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "missing session should exit 2, got $rc"
printf 'PASS: wait-comments exits 2 when no session exists\n'

# Baseline then new comment → 0
printf '%s\n' '{"comments":[{"noteId":"user:1","content":"old"}]}' >"$TMP_DIR/hunk-state"
(
  sleep 0.05
  printf '%s\n' '{"comments":[{"noteId":"user:1","content":"old"},{"noteId":"user:2","content":"new note"}]}' \
    >"$TMP_DIR/hunk-state"
) &
set +e
out="$("$SCRIPT" --repo . --timeout 5)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "new comment should exit 0, got $rc"
printf '%s' "$out" | jq -e '.comments | length == 1' >/dev/null \
  || fail "should emit only new comments: $out"
printf '%s' "$out" | jq -e '.comments[0].noteId == "user:2"' >/dev/null \
  || fail "should emit user:2, got $out"
printf 'PASS: wait-comments prints new user comments and exits 0\n'

# Session disappears after baseline → 2
printf '%s\n' '{"comments":[]}' >"$TMP_DIR/hunk-state"
(
  sleep 0.05
  rm -f "$TMP_DIR/hunk-state"
) &
set +e
"$SCRIPT" --repo . --timeout 5 >/dev/null
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "session gone should exit 2, got $rc"
printf 'PASS: wait-comments exits 2 when the session disappears\n'

# Timeout with no new comments → 124
printf '%s\n' '{"comments":[]}' >"$TMP_DIR/hunk-state"
set +e
"$SCRIPT" --repo . --timeout 1 >/dev/null
rc=$?
set -e
[[ "$rc" -eq 124 ]] || fail "timeout should exit 124, got $rc"
printf 'PASS: wait-comments exits 124 on timeout\n'
