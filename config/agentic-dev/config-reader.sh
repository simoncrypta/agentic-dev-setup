# Read ~/.config/agentic-dev/config.toml without external TOML parsers.

agentic_dev_agent_command() {
  local config="${HOME}/.config/agentic-dev/config.toml"
  local cmd="cursor-agent"
  if [[ -r "$config" ]]; then
    cmd="$(awk -F'"' '/^command[[:space:]]*=/ { print $2; exit }' "$config")"
  fi
  printf '%s' "${cmd:-cursor-agent}"
}

agentic_dev_layout_file_editor() {
  local config="${HOME}/.config/agentic-dev/config.toml"
  local editor="${EDITOR:-fresh}"
  if [[ -r "$config" ]]; then
    local from_config
    from_config="$(awk -F'"' '/^editor[[:space:]]*=/ { print $2; exit }' "$config")"
    if [[ -z "$from_config" ]]; then
      from_config="$(awk -F'"' '/^file_editor[[:space:]]*=/ { print $2; exit }' "$config")"
    fi
    [[ -n "$from_config" ]] && editor="$from_config"
  fi
  printf '%s' "$editor"
}

agentic_dev_layout_editor() {
  agentic_dev_layout_file_editor
}

agentic_dev_layout_review() {
  local config="${HOME}/.config/agentic-dev/config.toml"
  local review="hunk diff"
  if [[ -r "$config" ]]; then
    local from_config
    from_config="$(awk -F'"' '/^review[[:space:]]*=/ { print $2; exit }' "$config")"
    [[ -n "$from_config" ]] && review="$from_config"
  fi
  [[ "$review" == "hunk" ]] && review="hunk diff"
  printf '%s' "$review"
}
