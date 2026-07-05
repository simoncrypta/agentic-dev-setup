# Read agent/editor settings for the dev-layout plugin.
# Prefer HERDR_PLUGIN_CONFIG_DIR (Herdr convention), then agentic-dev full setup.

_dev_layout_config_file() {
  local candidate
  for candidate in \
    "${HERDR_PLUGIN_CONFIG_DIR:+$HERDR_PLUGIN_CONFIG_DIR/config.toml}" \
    "${HOME}/.config/agentic-dev/config.toml"; do
    [[ -n "$candidate" && -r "$candidate" ]] && printf '%s' "$candidate" && return 0
  done
  return 1
}

agentic_dev_agent_command() {
  local config cmd="agent"
  if config="$(_dev_layout_config_file)"; then
    cmd="$(awk -F'"' '/^command[[:space:]]*=/ { print $2; exit }' "$config")"
  fi
  printf '%s' "${cmd:-agent}"
}

agentic_dev_layout_editor() {
  local config editor="${EDITOR:-nvim}"
  if config="$(_dev_layout_config_file)"; then
    local from_config
    from_config="$(awk -F'"' '/^editor[[:space:]]*=/ { print $2; exit }' "$config")"
    [[ -n "$from_config" ]] && editor="$from_config"
  fi
  printf '%s' "$editor"
}
