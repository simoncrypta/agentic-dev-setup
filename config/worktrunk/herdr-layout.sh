# Herdr dev layout helpers for worktrunk and shell integration.

[[ -n "${WT_HERDR_LAYOUT_LOADED:-}" ]] && return 0
WT_HERDR_LAYOUT_LOADED=1

HERDR="${HERDR_BIN_PATH:-herdr}"
PLUGIN_ID="agentic-dev.dev-layout"

_wt_herdr_server_running() {
  herdr status server 2>/dev/null | grep -q '^status: running'
}

_wt_herdr_ensure_server() {
  _wt_herdr_server_running && return 0
  herdr status >/dev/null 2>&1 || true
  _wt_herdr_server_running
}

_wt_realpath() {
  local path="$1"
  (cd "$path" 2>/dev/null && pwd -P) || printf '%s' "$path"
}

_wt_git_main_worktree() {
  local workdir="$1"
  git -C "$workdir" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree / { print substr($0, 10); exit }'
}

_wt_herdr_workspace_id_by_label() {
  local label="$1"
  herdr workspace list 2>/dev/null \
    | jq -r --arg label "$label" '.result.workspaces[] | select(.label == $label) | .workspace_id' \
    | head -1
}

_wt_herdr_workspace_id_by_cwd() {
  local cwd="$1"
  local want ws_id pane_cwd
  want="$(_wt_realpath "$cwd")"
  while IFS= read -r ws_id; do
    [[ -n "$ws_id" ]] || continue
    pane_cwd="$(herdr pane list --workspace "$ws_id" 2>/dev/null \
      | jq -r '.result.panes[0].cwd // empty' | head -1)"
    [[ -n "$pane_cwd" ]] || continue
    if [[ "$(_wt_realpath "$pane_cwd")" == "$want" ]]; then
      printf '%s' "$ws_id"
      return 0
    fi
  done < <(herdr workspace list 2>/dev/null | jq -r '.result.workspaces[].workspace_id')
  return 1
}

_wt_in_herdr() {
  [[ -n "${HERDR_ENV:-}" || -n "${HERDR_PANE_ID:-}" ]]
}

_wt_generate_session_name() {
  local worktree_path="$1"
  local worktree_name repo_name branch

  worktree_name=$(basename "$worktree_path")

  if [[ "$worktree_name" == *.* ]]; then
    repo_name=$(echo "$worktree_name" | sed 's/\.[a-zA-Z0-9_-]*$//' | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
    branch=$(echo "$worktree_name" | sed 's/^[^.]*\.//' | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
  else
    repo_name=$(echo "$worktree_name" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
    branch=$(cd "$worktree_path" && git branch --show-current 2>/dev/null | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
  fi

  echo "${repo_name}_${branch}"
}

_wt_herdr_focus_workspace() {
  local label="$1"
  local workdir="${2:-}"
  local workspace_id

  _wt_herdr_ensure_server || return 1
  workspace_id="$(_wt_herdr_workspace_id_by_label "$label")"
  if [[ -z "$workspace_id" && -n "$workdir" ]]; then
    workspace_id="$(_wt_herdr_workspace_id_by_cwd "$workdir" 2>/dev/null || true)"
  fi
  if [[ -n "$workspace_id" ]]; then
    herdr workspace focus "$workspace_id" >/dev/null
    return 0
  fi
  return 1
}

# True when workdir is a linked git worktree (sibling checkout), not the main repo root.
_wt_is_linked_worktree() {
  local workdir="$1" main_path
  [[ -d "$workdir" ]] || return 1
  main_path="$(_wt_git_main_worktree "$workdir")"
  [[ -n "$main_path" ]] || return 1
  [[ "$(_wt_realpath "$workdir")" != "$(_wt_realpath "$main_path")" ]]
}

_wt_herdr_workspace_id_from_worktree_path() {
  local workdir="$1"
  local want
  want="$(_wt_realpath "$workdir")"
  herdr worktree list --cwd "$workdir" 2>/dev/null \
    | jq -r --arg want "$want" '
        .result.worktrees[]?
        | select((.path // "") != "")
        | select(.path == $want or (.path | sub("/$"; "")) == $want)
        | .open_workspace_id // empty
      ' \
    | head -1
}

# Open or create a Herdr worktree-group child for a linked checkout. Fail loud — no flat fallback.
_wt_herdr_resolve_linked_workspace() {
  local label="$1"
  local workdir="$2"
  local main_root branch workspace_id out

  workspace_id="$(_wt_herdr_workspace_id_from_worktree_path "$workdir")"
  if [[ -n "$workspace_id" && "$workspace_id" != "null" ]]; then
    printf '%s' "$workspace_id"
    return 0
  fi

  out="$(herdr worktree open --path "$workdir" --label "$label" --no-focus 2>/dev/null)" || out=""
  workspace_id="$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null || true)"
  if [[ -n "$workspace_id" && "$workspace_id" != "null" ]]; then
    printf '%s' "$workspace_id"
    return 0
  fi

  main_root="$(_wt_git_main_worktree "$workdir")"
  branch="$(git -C "$workdir" branch --show-current 2>/dev/null || true)"
  if [[ -z "$main_root" || -z "$branch" ]]; then
    echo "Cannot resolve main repo / branch for linked worktree: $workdir" >&2
    return 1
  fi

  out="$(herdr worktree create \
    --cwd "$main_root" \
    --branch "$branch" \
    --path "$workdir" \
    --label "$label" \
    --no-focus 2>/dev/null)" || out=""
  workspace_id="$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null || true)"
  if [[ -n "$workspace_id" && "$workspace_id" != "null" ]]; then
    printf '%s' "$workspace_id"
    return 0
  fi

  echo "Failed to open/create Herdr worktree subspace for: $workdir" >&2
  return 1
}

_wt_herdr_focused_workspace_id() {
  if [[ -n "${HERDR_WORKSPACE_ID:-}" ]]; then
    printf '%s' "$HERDR_WORKSPACE_ID"
    return 0
  fi
  herdr workspace list 2>/dev/null \
    | jq -r '.result.workspaces[]? | select(.focused == true) | .workspace_id' \
    | head -1
}

# Resolve (or create) the workspace id for workdir. Linked checkouts must use worktree APIs.
_wt_herdr_resolve_workspace() {
  local label="$1"
  local workdir="$2"
  local workspace_id

  workspace_id="$(_wt_herdr_workspace_id_by_label "$label")"
  if [[ -z "$workspace_id" ]]; then
    workspace_id="$(_wt_herdr_workspace_id_by_cwd "$workdir" 2>/dev/null || true)"
  fi

  if [[ -z "$workspace_id" ]]; then
    if _wt_is_linked_worktree "$workdir"; then
      workspace_id="$(_wt_herdr_resolve_linked_workspace "$label" "$workdir")" || return 1
    else
      workspace_id="$(herdr workspace create --cwd "$workdir" --label "$label" --no-focus 2>/dev/null \
        | jq -r '.result.workspace.workspace_id')"
    fi
  fi

  [[ -n "$workspace_id" && "$workspace_id" != "null" ]] || {
    echo "Failed to resolve Herdr workspace '$label' for $workdir" >&2
    return 1
  }

  herdr workspace rename "$workspace_id" "$label" >/dev/null 2>&1 || true
  printf '%s' "$workspace_id"
}

# Focus → sticky layout create → always restore previous focus (attach re-focuses if needed).
_wt_herdr_apply_layout() {
  local workspace_id="$1"
  local prev_ws=""

  prev_ws="$(_wt_herdr_focused_workspace_id 2>/dev/null || true)"
  herdr workspace focus "$workspace_id" >/dev/null
  "$HERDR" plugin action invoke "${PLUGIN_ID}.create" >/dev/null
  if [[ -n "$prev_ws" && "$prev_ws" != "null" && "$prev_ws" != "$workspace_id" ]]; then
    herdr workspace focus "$prev_ws" >/dev/null 2>&1 || true
  fi
}

wt_herdr_layout_create() {
  local label="$1"
  local workdir="$2"
  local workspace_id

  _wt_herdr_ensure_server || {
    echo "Herdr server is not running. Start it with: herdr" >&2
    return 1
  }

  workspace_id="$(_wt_herdr_resolve_workspace "$label" "$workdir")" || return 1
  _wt_herdr_apply_layout "$workspace_id"
}

wt_herdr_layout_apply() {
  local workdir="${1:-$PWD}"
  local label="${2:-}"
  local workspace_id

  _wt_herdr_ensure_server || return 1

  if _wt_in_herdr && [[ -n "${HERDR_WORKSPACE_ID:-}" ]]; then
    workspace_id="$HERDR_WORKSPACE_ID"
    label="$(herdr workspace get "$workspace_id" 2>/dev/null \
      | jq -r '.result.workspace.label // empty')"
  fi

  if [[ -z "$label" ]]; then
    label="$(_wt_generate_session_name "$workdir" 2>/dev/null || basename "$workdir")"
  fi

  workspace_id="${workspace_id:-$(_wt_herdr_workspace_id_by_label "$label")}"
  [[ -n "$workspace_id" ]] || workspace_id="$(_wt_herdr_workspace_id_by_cwd "$workdir" 2>/dev/null || true)"
  [[ -n "$workspace_id" ]] && herdr workspace focus "$workspace_id" >/dev/null

  "$HERDR" plugin action invoke "${PLUGIN_ID}.apply" >/dev/null
}

wt_herdr_layout_close() {
  local label="$1"
  local workspace_id

  _wt_herdr_ensure_server || return 0
  workspace_id="$(_wt_herdr_workspace_id_by_label "$label")"
  [[ -n "$workspace_id" ]] || return 0

  # Close the Herdr subspace only (do not git-remove the worktree here — Worktrunk owns that).
  herdr workspace close "$workspace_id" >/dev/null 2>&1 || true
}

wt_herdr_attach() {
  local worktree_path="$1"
  local session_name

  session_name="$(_wt_generate_session_name "$worktree_path")"
  wt_herdr_layout_create "$session_name" "$worktree_path"
  _wt_herdr_focus_workspace "$session_name" "$worktree_path" || true

  if [[ -n "${HERDR_ENV:-}" || -n "${HERDR_PANE_ID:-}" ]]; then
    return 0
  fi

  if [[ -z "${WT_HERDR_NO_ATTACH:-}" ]]; then
    herdr
  fi
}
