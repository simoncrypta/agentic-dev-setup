#!/usr/bin/env bash
# Wait until hunk has new human comments, the live session disappears, or timeout.
# Exit 0: print new comments JSON. Exit 2: no session. Exit 124: timeout.
set -euo pipefail

HUNK_BIN="${HUNK_BIN:-hunk}"
REPO="."
TIMEOUT=600
INTERVAL="${WAIT_COMMENTS_POLL_SECONDS:-2}"

usage() {
  printf 'usage: wait-comments.sh --repo <path> [--timeout <seconds>]\n' >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || usage
      REPO="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || usage
      TIMEOUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || usage

comment_ids() {
  local json="$1"
  printf '%s' "$json" | jq -r '
    ((.comments // .notes // .) | if type == "array" then . else [] end)
    | .[]
    | (.noteId // .id // .commentId // empty)
  ' 2>/dev/null || true
}

list_comments() {
  local out rc=0
  set +e
  out="$("$HUNK_BIN" session comment list --repo "$REPO" --type user --json 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]] || printf '%s' "$out" | grep -qiE 'no active hunk sessions|no active session'; then
    return 2
  fi
  printf '%s' "$out"
  return 0
}

ids_to_lines() {
  comment_ids "$1" | awk 'NF' | sort -u
}

new_ids_since() {
  local baseline="$1" current="$2"
  comm -13 <(printf '%s\n' "$baseline") <(printf '%s\n' "$current")
}

filter_comments() {
  local json="$1"
  shift
  local -a ids=("$@")
  local jq_ids
  jq_ids="$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s .)"
  printf '%s' "$json" | jq --argjson ids "$jq_ids" '
    def items: (.comments // .notes // .) | if type == "array" then . else [] end;
    def cid: .noteId // .id // .commentId // "";
    {comments: [items[] | select(cid as $c | $ids | index($c))]}
  '
}

start="$SECONDS"
json=""
if ! json="$(list_comments)"; then
  exit 2
fi
baseline="$(ids_to_lines "$json")"

while (( SECONDS - start < TIMEOUT )); do
  sleep "$INTERVAL"
  if ! json="$(list_comments)"; then
    exit 2
  fi
  current="$(ids_to_lines "$json")"
  mapfile -t added < <(new_ids_since "$baseline" "$current")
  if ((${#added[@]})); then
    filter_comments "$json" "${added[@]}"
    printf '\n'
    exit 0
  fi
done

exit 124
