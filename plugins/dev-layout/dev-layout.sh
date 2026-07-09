#!/usr/bin/env bash
# Herdr dev layout: sticky agent pane (left 50%) + review/explorer/terminal tabs.
set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
STATE_VERSION=1
TABS=(review explorer terminal)

_plugin_root() {
  if [[ -n "${HERDR_PLUGIN_ROOT:-}" ]]; then
    printf '%s' "$HERDR_PLUGIN_ROOT"
  else
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
  fi
}

# shellcheck source=/dev/null
source "$(_plugin_root)/config-reader.sh"

_state_dir() {
  if [[ -n "${HERDR_PLUGIN_STATE_DIR:-}" ]]; then
    printf '%s' "$HERDR_PLUGIN_STATE_DIR"
    return 0
  fi
  printf '%s' "${XDG_STATE_HOME:-${HOME}/.local/state}/herdr/plugins/agentic-dev.dev-layout"
}

_state_path() {
  local workspace_id="$1"
  mkdir -p "$(_state_dir)"
  printf '%s/%s.json' "$(_state_dir)" "$workspace_id"
}

_agent_cmd() {
  if declare -F agentic_dev_agent_command >/dev/null 2>&1; then
    agentic_dev_agent_command
  else
    printf '%s' "agent"
  fi
}

_editor() {
  if declare -F agentic_dev_layout_editor >/dev/null 2>&1; then
    agentic_dev_layout_editor
  else
    printf '%s' "${EDITOR:-nvim}"
  fi
}

_herdr_json() {
  "$HERDR" "$@" 2>/dev/null
}

_jq() {
  jq -r "$@"
}

_tool_command() {
  local tab="$1"
  local editor
  editor="$(_editor)"
  case "$tab" in
    review) printf '%s' "tuicr; exec bash -li" ;;
    explorer) printf '%s' "${editor} .; exec bash -li" ;;
    terminal) printf '%s' "clear; exec bash -li" ;;
    *) return 1 ;;
  esac
}

_focused_workspace_id() {
  _herdr_json workspace list \
    | _jq '.result.workspaces[] | select(.focused == true) | .workspace_id' \
    | head -1
}

_workspace_id_by_label() {
  local label="$1"
  _herdr_json workspace list \
    | _jq --arg label "$label" '.result.workspaces[] | select(.label == $label) | .workspace_id' \
    | head -1
}

_workspace_id_by_cwd() {
  local cwd="$1"
  local ws_id pane_cwd
  while IFS= read -r ws_id; do
    [[ -n "$ws_id" ]] || continue
    pane_cwd="$(_herdr_json pane list --workspace "$ws_id" \
      | _jq '.result.panes[0].cwd // empty' \
      | head -1)"
    if [[ "$pane_cwd" == "$cwd" ]]; then
      printf '%s' "$ws_id"
      return 0
    fi
  done < <(_herdr_json workspace list | _jq '.result.workspaces[].workspace_id')
  return 1
}

_pane_exists() {
  local pane_id="$1"
  [[ -n "$pane_id" ]] || return 1
  _herdr_json pane get "$pane_id" >/dev/null 2>&1
}

# Serialize layout mutations per workspace. Concurrent create/apply (e.g. worktrunk
# post-start + wtc/dev attach) otherwise race and open duplicate agent panes.
_layout_lock_acquire() {
  local workspace_id="$1"
  local lockfile
  mkdir -p "$(_state_dir)"
  lockfile="$(_state_dir)/${workspace_id}.lock"
  exec 9>"$lockfile"
  flock 9
}

_layout_lock_release() {
  flock -u 9 2>/dev/null || true
  exec 9>&- 2>/dev/null || true
}

_extra_panes_on_tab() {
  local workspace_id="$1" tab_id="$2" tool_pane="$3"
  _herdr_json pane list --workspace "$workspace_id" \
    | _jq --arg tab "$tab_id" --arg tool "$tool_pane" \
      '.result.panes[] | select(.tab_id == $tab and .pane_id != $tool) | .pane_id'
}

_close_orphan_agent_panes() {
  local workspace_id="$1" tab_id="$2" tool_pane="$3" keep_pane="${4:-}"
  local pane_id
  while IFS= read -r pane_id; do
    [[ -n "$pane_id" ]] || continue
    [[ "$pane_id" == "$keep_pane" ]] && continue
    _herdr_json pane close "$pane_id" >/dev/null 2>&1 || true
  done < <(_extra_panes_on_tab "$workspace_id" "$tab_id" "$tool_pane")
}

_state_load() {
  local workspace_id="$1"
  local path
  path="$(_state_path "$workspace_id")"
  [[ -f "$path" ]] || return 1
  cat "$path"
}

_state_save() {
  local workspace_id="$1"
  local json="$2"
  printf '%s' "$json" > "$(_state_path "$workspace_id")"
}

_state_delete() {
  local workspace_id="$1"
  rm -f "$(_state_path "$workspace_id")"
}

_state_init() {
  local workspace_id="$1" label="$2" workdir="$3"
  jq -n \
    --arg workspace_id "$workspace_id" \
    --arg label "$label" \
    --arg workdir "$workdir" \
    --argjson version "$STATE_VERSION" \
    '{
      workspace_id: $workspace_id,
      label: $label,
      workdir: $workdir,
      version: $version,
      agent_pane_id: "",
      active_tab: "review",
      tabs: {}
    }'
}

_state_set_tab() {
  local state="$1" tab="$2" tab_id="$3" tool_pane_id="$4"
  printf '%s' "$state" | jq \
    --arg tab "$tab" \
    --arg tab_id "$tab_id" \
    --arg tool_pane_id "$tool_pane_id" \
    '.tabs[$tab] = {tab_id: $tab_id, tool_pane_id: $tool_pane_id}'
}

_state_get_tab_id() {
  local state="$1" tab="$2"
  printf '%s' "$state" | _jq --arg tab "$tab" '.tabs[$tab].tab_id // empty'
}

_state_get_tool_pane() {
  local state="$1" tab="$2"
  printf '%s' "$state" | _jq --arg tab "$tab" '.tabs[$tab].tool_pane_id // empty'
}

_ensure_workspace() {
  local label="$1" workdir="$2"
  local workspace_id

  workspace_id="$(_workspace_id_by_label "$label")"
  if [[ -z "$workspace_id" ]]; then
    workspace_id="$(_workspace_id_by_cwd "$workdir" 2>/dev/null || true)"
  fi

  if [[ -n "$workspace_id" ]]; then
    _herdr_json workspace rename "$workspace_id" "$label" >/dev/null || true
    _herdr_json workspace focus "$workspace_id" >/dev/null
    printf '%s' "$workspace_id"
    return 0
  fi

  workspace_id="$(_herdr_json workspace create --cwd "$workdir" --label "$label" --focus \
    | _jq '.result.workspace.workspace_id')"
  printf '%s' "$workspace_id"
}

_ensure_tab() {
  local workspace_id="$1" tab="$2" workdir="$3" state="$4"
  local tab_id tool_pane_id existing

  tab_id="$(_state_get_tab_id "$state" "$tab")"
  if [[ -n "$tab_id" ]]; then
    tool_pane_id="$(_state_get_tool_pane "$state" "$tab")"
    if _pane_exists "$tool_pane_id"; then
      printf '%s\t%s' "$tab_id" "$tool_pane_id"
      return 0
    fi
  fi

  existing="$(_herdr_json tab list --workspace "$workspace_id" \
    | _jq --arg tab "$tab" '.result.tabs[] | select(.label == $tab) | .tab_id' \
    | head -1)"
  if [[ -n "$existing" ]]; then
    tool_pane_id="$(_herdr_json pane list --workspace "$workspace_id" \
      | _jq --arg tab "$existing" '.result.panes[] | select(.tab_id == $tab) | .pane_id' \
      | head -1)"
    if _pane_exists "$tool_pane_id"; then
      printf '%s\t%s' "$existing" "$tool_pane_id"
      return 0
    fi
  fi

  local create_json tool_cmd
  tool_cmd="$(_tool_command "$tab")"
  create_json="$(_herdr_json tab create --workspace "$workspace_id" --cwd "$workdir" --label "$tab" --no-focus)"
  tab_id="$(printf '%s' "$create_json" | _jq '.result.tab.tab_id')"
  tool_pane_id="$(printf '%s' "$create_json" | _jq '.result.root_pane.pane_id')"

  _herdr_json pane run "$tool_pane_id" "bash -li -c $(printf '%q' "$tool_cmd")" >/dev/null || true
  printf '%s\t%s' "$tab_id" "$tool_pane_id"
}

_ensure_agent_pane() {
  local workspace_id="$1" workdir="$2" state="$3" tab="$4"
  local agent_pane tool_pane tab_id existing

  tab_id="$(_state_get_tab_id "$state" "$tab")"
  tool_pane="$(_state_get_tool_pane "$state" "$tab")"
  [[ -n "$tab_id" && -n "$tool_pane" ]] || return 1

  agent_pane="$(printf '%s' "$state" | _jq '.agent_pane_id // empty')"
  if _pane_exists "$agent_pane"; then
    _close_orphan_agent_panes "$workspace_id" "$tab_id" "$tool_pane" "$agent_pane"
    printf '%s' "$agent_pane"
    return 0
  fi

  # Reclaim a leftover split from a raced create before opening another.
  existing="$(_extra_panes_on_tab "$workspace_id" "$tab_id" "$tool_pane" | head -1)"
  if [[ -n "$existing" ]] && _pane_exists "$existing"; then
    _close_orphan_agent_panes "$workspace_id" "$tab_id" "$tool_pane" "$existing"
    printf '%s' "$existing"
    return 0
  fi

  _herdr_json tab focus "$tab_id" >/dev/null
  agent_pane="$(_herdr_json pane split "$tool_pane" --direction right --ratio 0.5 --cwd "$workdir" --no-focus \
    | _jq '.result.pane.pane_id')"
  _herdr_json pane swap --source-pane "$agent_pane" --target-pane "$tool_pane" >/dev/null 2>&1 || true
  _herdr_json pane run "$agent_pane" "$(_agent_cmd)" >/dev/null || true
  printf '%s' "$agent_pane"
}

_attach_agent_to_tab() {
  local state="$1" tab="$2"
  local agent_pane tab_id tool_pane agent_tab

  agent_pane="$(printf '%s' "$state" | _jq '.agent_pane_id // empty')"
  tab_id="$(_state_get_tab_id "$state" "$tab")"
  tool_pane="$(_state_get_tool_pane "$state" "$tab")"

  [[ -n "$agent_pane" && -n "$tab_id" && -n "$tool_pane" ]] || return 0
  _pane_exists "$agent_pane" || return 0
  _pane_exists "$tool_pane" || return 0

  agent_tab="$(_herdr_json pane get "$agent_pane" | _jq '.result.pane.tab_id // .result.tab_id // empty' 2>/dev/null || \
    _herdr_json pane list | _jq --arg p "$agent_pane" '.result.panes[] | select(.pane_id == $p) | .tab_id')"
  if [[ "$agent_tab" == "$tab_id" ]]; then
    return 0
  fi

  _herdr_json pane move "$agent_pane" --tab "$tab_id" --split right --ratio 0.5 --target-pane "$tool_pane" --no-focus >/dev/null
  _herdr_json pane swap --source-pane "$agent_pane" --target-pane "$tool_pane" >/dev/null 2>&1 || true
}

_layout_ensure() {
  local label="${WT_HERDR_LABEL:-}" workdir="${WT_HERDR_WORKDIR:-}"
  local workspace_id state tab tab_id tool_pane agent_pane line

  if [[ -z "$label" || -z "$workdir" ]]; then
    workspace_id="${HERDR_WORKSPACE_ID:-$(_focused_workspace_id)}"
    [[ -n "$workspace_id" ]] || { echo "dev-layout: no workspace context" >&2; exit 1; }
    state="$(_state_load "$workspace_id" 2>/dev/null || true)"
    if [[ -n "$state" ]]; then
      label="$(printf '%s' "$state" | _jq '.label')"
      workdir="$(printf '%s' "$state" | _jq '.workdir')"
    else
      label="$(_herdr_json workspace get "$workspace_id" | _jq '.result.workspace.label // empty')"
      workdir="$(_herdr_json pane list --workspace "$workspace_id" \
        | _jq '.result.panes[0].cwd // empty' | head -1)"
      workdir="${workdir:-$PWD}"
      label="${label:-$workdir}"
    fi
  fi

  workspace_id="$(_ensure_workspace "$label" "$workdir")"
  _layout_lock_acquire "$workspace_id"
  # shellcheck disable=SC2064
  trap '_layout_lock_release' RETURN

  state="$(_state_load "$workspace_id" 2>/dev/null || _state_init "$workspace_id" "$label" "$workdir")"
  state="$(printf '%s' "$state" | jq --arg wid "$workspace_id" --arg label "$label" --arg workdir "$workdir" \
    '.workspace_id = $wid | .label = $label | .workdir = $workdir')"

  if [[ -z "$(_state_get_tab_id "$state" "review")" ]]; then
    local root_tab root_pane
    root_tab="$(_herdr_json workspace get "$workspace_id" | _jq '.result.workspace.active_tab_id // empty')"
    root_pane="$(_herdr_json pane list --workspace "$workspace_id" \
      | _jq '.result.panes[0].pane_id // empty' | head -1)"
    if [[ -n "$root_tab" && -n "$root_pane" ]]; then
      _herdr_json tab rename "$root_tab" review >/dev/null 2>&1 || true
      _herdr_json pane run "$root_pane" "bash -li -c $(printf '%q' "$(_tool_command review)")" >/dev/null || true
      state="$(_state_set_tab "$state" review "$root_tab" "$root_pane")"
    fi
  fi

  for tab in "${TABS[@]}"; do
    if [[ "$tab" == "review" && -n "$(_state_get_tab_id "$state" "review")" ]]; then
      continue
    fi
    line="$(_ensure_tab "$workspace_id" "$tab" "$workdir" "$state")"
    tab_id="${line%%$'\t'*}"
    tool_pane="${line#*$'\t'}"
    state="$(_state_set_tab "$state" "$tab" "$tab_id" "$tool_pane")"
  done

  agent_pane="$(_ensure_agent_pane "$workspace_id" "$workdir" "$state" "review")"
  state="$(printf '%s' "$state" | jq --arg agent "$agent_pane" '.agent_pane_id = $agent')"
  _state_save "$workspace_id" "$state"
  printf '%s' "$state"
}

_select_tab() {
  local tab="$1"
  local state workspace_id tab_id

  state="$(_layout_ensure)"
  workspace_id="$(printf '%s' "$state" | _jq '.workspace_id')"
  tab_id="$(_state_get_tab_id "$state" "$tab")"

  _attach_agent_to_tab "$state" "$tab"
  _herdr_json tab focus "$tab_id" >/dev/null
  if [[ "$tab" != "agent" ]]; then
    _herdr_json tab focus "$tab_id" >/dev/null
    _herdr_json pane focus --direction right >/dev/null 2>&1 || true
  fi

  state="$(printf '%s' "$state" | jq --arg tab "$tab" '.active_tab = $tab')"
  _state_save "$workspace_id" "$state"
}

_focus_agent() {
  local state workspace_id tab agent_pane tab_id

  state="$(_layout_ensure)"
  workspace_id="$(printf '%s' "$state" | _jq '.workspace_id')"
  tab="$(printf '%s' "$state" | _jq '.active_tab // "review"')"
  agent_pane="$(printf '%s' "$state" | _jq '.agent_pane_id // empty')"
  tab_id="$(_state_get_tab_id "$state" "$tab")"

  _attach_agent_to_tab "$state" "$tab"
  _herdr_json tab focus "$tab_id" >/dev/null
  if _pane_exists "$agent_pane"; then
    _herdr_json agent focus "$agent_pane" >/dev/null 2>&1 \
      || _herdr_json pane focus --direction left >/dev/null 2>&1 \
      || true
  fi
}

_on_pane_exited() {
  local pane_id="${1:-}"
  local workspace_id state agent_pane

  [[ -n "$pane_id" ]] || return 0
  for path in "$(_state_dir)"/*.json; do
    [[ -f "$path" ]] || continue
    state="$(cat "$path")"
    agent_pane="$(printf '%s' "$state" | _jq '.agent_pane_id // empty')"
    if [[ "$agent_pane" == "$pane_id" ]]; then
      workspace_id="$(printf '%s' "$state" | _jq '.workspace_id')"
      state="$(printf '%s' "$state" | jq '.agent_pane_id = ""')"
      _state_save "$workspace_id" "$state"
    fi
  done
}

_on_workspace_closed() {
  local workspace_id="${1:-}"
  [[ -n "$workspace_id" ]] || return 0
  _state_delete "$workspace_id"
}

_resolve_context() {
  if [[ -n "${WT_HERDR_LABEL:-}" && -n "${WT_HERDR_WORKDIR:-}" ]]; then
    return 0
  fi
  if [[ -n "${HERDR_WORKSPACE_ID:-}" ]]; then
    return 0
  fi
  local focused
  focused="$(_focused_workspace_id)"
  [[ -n "$focused" ]] && export HERDR_WORKSPACE_ID="$focused"
}

main() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || cmd="${HERDR_PLUGIN_ACTION_ID:-}"
  [[ -n "$cmd" ]] || cmd="${HERDR_PLUGIN_EVENT:-}"

  case "$cmd" in
    create|apply)
      _resolve_context
      _select_tab review
      ;;
    focus_agent)
      _resolve_context
      _focus_agent
      ;;
    select_review) _resolve_context; _select_tab review ;;
    select_explorer) _resolve_context; _select_tab explorer ;;
    select_terminal) _resolve_context; _select_tab terminal ;;
    event_pane_exited|pane.exited)
      local pane_id
      pane_id="$(printf '%s' "${HERDR_PLUGIN_EVENT_JSON:-{}}" | _jq '.pane_id // .pane.pane_id // empty' 2>/dev/null || true)"
      _on_pane_exited "$pane_id"
      ;;
    event_workspace_closed|workspace.closed)
      local workspace_id
      workspace_id="$(printf '%s' "${HERDR_PLUGIN_EVENT_JSON:-{}}" | _jq '.workspace_id // .workspace.workspace_id // empty' 2>/dev/null || true)"
      _on_workspace_closed "$workspace_id"
      ;;
    *)
      echo "dev-layout: unknown command '$cmd'" >&2
      exit 1
      ;;
  esac
}

main "$@"
