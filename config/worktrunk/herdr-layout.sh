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

_wt_herdr_workspace_id_by_label() {
  local label="$1"
  herdr workspace list 2>/dev/null \
    | jq -r --arg label "$label" '.result.workspaces[] | select(.label == $label) | .workspace_id' \
    | head -1
}

_wt_herdr_workspace_id_by_cwd() {
  local cwd="$1"
  local ws_id pane_cwd
  while IFS= read -r ws_id; do
    [[ -n "$ws_id" ]] || continue
    pane_cwd="$(herdr pane list --workspace "$ws_id" 2>/dev/null \
      | jq -r '.result.panes[0].cwd // empty' | head -1)"
    if [[ "$pane_cwd" == "$cwd" ]]; then
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

wt_herdr_layout_create() {
  local label="$1"
  local workdir="$2"
  local workspace_id

  _wt_herdr_ensure_server || {
    echo "Herdr server is not running. Start it with: herdr" >&2
    return 1
  }

  workspace_id="$(_wt_herdr_workspace_id_by_label "$label")"
  if [[ -z "$workspace_id" ]]; then
    workspace_id="$(_wt_herdr_workspace_id_by_cwd "$workdir" 2>/dev/null || true)"
  fi

  if [[ -z "$workspace_id" ]]; then
    workspace_id="$(herdr workspace create --cwd "$workdir" --label "$label" --no-focus 2>/dev/null \
      | jq -r '.result.workspace.workspace_id')"
  else
    herdr workspace rename "$workspace_id" "$label" >/dev/null 2>&1 || true
  fi

  [[ -n "$workspace_id" && "$workspace_id" != "null" ]] || {
    echo "Failed to create Herdr workspace '$label'" >&2
    return 1
  }

  herdr workspace focus "$workspace_id" >/dev/null
  "$HERDR" plugin action invoke "${PLUGIN_ID}.create" >/dev/null
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
