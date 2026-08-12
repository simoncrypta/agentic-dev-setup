#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

FAKE_BIN="$TMP_DIR/bin"
HERDR_CALL_LOG="$TMP_DIR/herdr-calls.log"
mkdir -p "$FAKE_BIN" "$TMP_DIR/main" "$TMP_DIR/main.feature"
export PATH="$FAKE_BIN:$PATH"
export HOME="$TMP_DIR/home"
mkdir -p "$HOME"
export HERDR_CALL_LOG
export HERDR_WORKSPACE_ID="w-parent"

cat >"$FAKE_BIN/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
MAIN="$TMP_DIR/main"
LINKED="$TMP_DIR/main.feature"
if [[ "\${1:-}" == "-C" ]]; then
  dir="\$2"
  shift 2
else
  dir="\$PWD"
fi
case "\$*" in
  "worktree list --porcelain")
    printf 'worktree %s\\n' "\$MAIN"
    printf 'HEAD abc\\nbranch refs/heads/master\\n\\n'
    printf 'worktree %s\\n' "\$LINKED"
    printf 'HEAD def\\nbranch refs/heads/feature\\n\\n'
    ;;
  "branch --show-current")
    if [[ "\$dir" == "\$LINKED" ]]; then
      printf 'feature\\n'
    else
      printf 'master\\n'
    fi
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$FAKE_BIN/git"

write_fake_herdr() {
  local mode="$1"
  cat >"$FAKE_BIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "\$*" >>"\${HERDR_CALL_LOG}"
mode="$mode"
case "\$*" in
  "status server")
    printf 'status: running\\n'
    ;;
  workspace\\ list*)
    printf '{"result":{"workspaces":[{"workspace_id":"w-parent","label":"parent","focused":true}]}}\\n'
    ;;
  worktree\\ list*)
    printf '{"result":{"worktrees":[]}}\\n'
    ;;
  worktree\\ open*)
    if [[ "\$mode" == "open-fail" || "\$mode" == "all-fail" ]]; then
      exit 1
    fi
    printf '{"result":{"workspace":{"workspace_id":"w-child"}}}\\n'
    ;;
  worktree\\ create*)
    if [[ "\$mode" == "all-fail" ]]; then
      exit 1
    fi
    printf '{"result":{"workspace":{"workspace_id":"w-created"}}}\\n'
    ;;
  workspace\\ create*)
    printf '{"result":{"workspace":{"workspace_id":"w-flat"}}}\\n'
    ;;
  workspace\\ focus*|workspace\\ rename*|plugin\\ action*)
    printf '{}\\n'
    ;;
  *)
    printf '{}\\n'
    ;;
esac
EOF
  chmod +x "$FAKE_BIN/herdr"
}

# shellcheck source=config/worktrunk/herdr-layout.sh
source "$ROOT/config/worktrunk/herdr-layout.sh"

write_fake_herdr open-ok
: >"$HERDR_CALL_LOG"
wt_herdr_layout_create "Main_Feature" "$TMP_DIR/main.feature" >/dev/null

grep -qE '^worktree open --path .*main\.feature' "$HERDR_CALL_LOG" \
  || fail "expected herdr worktree open for linked worktree; log=$(cat "$HERDR_CALL_LOG")"
grep -qE '^workspace create ' "$HERDR_CALL_LOG" \
  && fail "should not fall back to workspace create when worktree open succeeds"
grep -q 'plugin action invoke agentic-dev.dev-layout.create' "$HERDR_CALL_LOG" \
  || fail "expected sticky layout create"
grep -qE '^workspace focus w-parent$' "$HERDR_CALL_LOG" \
  || fail "expected restore focus to parent; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: linked worktree uses herdr worktree open + restores focus\n'

write_fake_herdr open-ok
: >"$HERDR_CALL_LOG"
wt_herdr_layout_create "Main_Master" "$TMP_DIR/main" >/dev/null
grep -qE '^workspace create --cwd .*main ' "$HERDR_CALL_LOG" \
  || fail "main checkout should use workspace create; log=$(cat "$HERDR_CALL_LOG")"
grep -qE '^worktree open ' "$HERDR_CALL_LOG" \
  && fail "main checkout should not use worktree open"
printf 'PASS: main checkout uses workspace create\n'

write_fake_herdr all-fail
: >"$HERDR_CALL_LOG"
if wt_herdr_layout_create "Main_Feature" "$TMP_DIR/main.feature" >/dev/null 2>&1; then
  fail "linked worktree should fail loud when open/create fail"
fi
grep -qE '^workspace create ' "$HERDR_CALL_LOG" \
  && fail "linked failure must not fall through to flat workspace create; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: linked worktree fails without flat fallback\n'
