# Read ~/.config/agentic-dev/config.toml without external TOML parsers.

agentic_dev_agent_command() {
  local config="${HOME}/.config/agentic-dev/config.toml"
  local cmd="cursor-agent"
  if [[ -r "$config" ]]; then
    cmd="$(awk -F'"' '/^command[[:space:]]*=/ { print $2; exit }' "$config")"
  fi
  printf '%s' "${cmd:-cursor-agent}"
}

agentic_dev_layout_editor() {
  local config="${HOME}/.config/agentic-dev/config.toml"
  local editor="${EDITOR:-nvim}"
  if [[ -r "$config" ]]; then
    local from_config
    from_config="$(awk -F'"' '/^editor[[:space:]]*=/ { print $2; exit }' "$config")"
    [[ -n "$from_config" ]] && editor="$from_config"
  fi
  printf '%s' "$editor"
}

agentic_dev_layout_review() {
  local config="${HOME}/.config/agentic-dev/config.toml"
  local review="tuicr"
  if [[ -r "$config" ]]; then
    local from_config
    from_config="$(awk -F'"' '/^review[[:space:]]*=/ { print $2; exit }' "$config")"
    [[ -n "$from_config" ]] && review="$from_config"
  fi
  printf '%s' "$review"
}
