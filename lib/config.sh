#!/usr/bin/env bash
# shellcheck shell=bash

default_user_config() {
  cat <<'EOF'
[agent]
command = "agent"

[layout]
editor = "nvim"
EOF
}

_config_reader_path() {
  local src
  src="$(install_src_dir)"
  if [[ -d "$src" && -f "$src/config/agentic-dev/config-reader.sh" ]]; then
    printf '%s' "$src/config/agentic-dev/config-reader.sh"
    return 0
  fi
  if [[ -f "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh" ]]; then
    printf '%s' "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh"
    return 0
  fi
  return 1
}

ensure_config_reader() {
  declare -F agentic_dev_agent_command >/dev/null 2>&1 && return 0
  local reader
  reader="$(_config_reader_path)" || return 1
  # shellcheck source=/dev/null
  source "$reader"
}

read_agent_command() {
  ensure_config_reader || true
  if declare -F agentic_dev_agent_command >/dev/null 2>&1; then
    agentic_dev_agent_command
  else
    printf '%s' "agent"
  fi
}

read_layout_editor() {
  ensure_config_reader || true
  if declare -F agentic_dev_layout_editor >/dev/null 2>&1; then
    agentic_dev_layout_editor
  else
    printf '%s' "${EDITOR:-nvim}"
  fi
}

RECONFIGURE=0

prompt_agent_command() {
  if [[ -f "$AGENTIC_DEV_USER_CONFIG" ]] && [[ "$RECONFIGURE" -ne 1 ]]; then
    info "using existing agent command: $(read_agent_command)"
    return 0
  fi

  if [[ "$YES" -eq 1 ]]; then
    ensure_dir "$AGENTIC_DEV_CONFIG_DIR"
    if [[ ! -f "$AGENTIC_DEV_USER_CONFIG" ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] would write default $AGENTIC_DEV_USER_CONFIG"
      else
        default_user_config >"$AGENTIC_DEV_USER_CONFIG"
      fi
    fi
    return 0
  fi

  log ""
  log "Which command should the agent pane auto-start?"
  log "  1) agent"
  log "  2) codex"
  log "  3) opencode"
  log "  4) claude"
  log "  5) custom"
  log ""
  printf 'Choice [1-5]: '
  local choice custom_cmd cmd="agent"
  read -r choice
  case "$choice" in
    1|agent) cmd="agent" ;;
    2|codex) cmd="codex" ;;
    3|opencode) cmd="opencode" ;;
    4|claude) cmd="claude" ;;
    5|custom)
      printf 'Enter custom command: '
      read -r custom_cmd
      cmd="${custom_cmd:-agent}"
      ;;
    ""|*) cmd="agent" ;;
  esac

  local editor
  editor="$(read_layout_editor)"
  ensure_dir "$AGENTIC_DEV_CONFIG_DIR"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would write $AGENTIC_DEV_USER_CONFIG (agent=$cmd)"
    return 0
  fi
  cat >"$AGENTIC_DEV_USER_CONFIG" <<EOF
[agent]
command = "$cmd"

[layout]
editor = "$editor"
EOF
  info "saved agent command to $AGENTIC_DEV_USER_CONFIG"
}

deploy_tree() {
  local src="$1"
  local dest="$2"
  [[ -d "$src" ]] || return 0
  ensure_dir "$dest"
  while IFS= read -r -d '' file; do
    local sub="${file#"$src"/}"
    copy_file "$file" "$dest/$sub"
  done < <(find "$src" -type f -print0)
}

deploy_install_file() {
  local rel="$1" dest="$2"
  local src
  src="$(install_src_dir)"
  if [[ -d "$src" ]]; then
    copy_file "$src/$rel" "$dest"
  else
    fetch_file "$rel" "$dest"
  fi
}

deploy_agentic_dev_config() {
  local src file sub
  src="$(install_src_dir)"
  if [[ -d "$src" ]]; then
    while IFS= read -r -d '' file; do
      sub="${file#"$src/config/agentic-dev"/}"
      [[ "$sub" == "config.toml" ]] && continue
      copy_file "$file" "$AGENTIC_DEV_CONFIG_DIR/$sub"
    done < <(find "$src/config/agentic-dev" -type f -print0 2>/dev/null)
  else
    deploy_install_file "config/agentic-dev/config-reader.sh" "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh"
    deploy_install_file "config/agentic-dev/config.toml.example" "$AGENTIC_DEV_CONFIG_DIR/config.toml.example"
  fi
}

deploy_lib() {
  local src
  src="$(install_src_dir)"
  if [[ -d "$src" ]]; then
    deploy_tree "$src/lib" "${HOME}/.local/share/agentic-dev/lib"
  else
    local libfile
    for libfile in common.sh detect.sh deps.sh config.sh shell-rc.sh uninstall.sh help.sh omarchy.sh; do
      deploy_install_file "lib/$libfile" "${HOME}/.local/share/agentic-dev/lib/$libfile"
    done
  fi
}

deploy_plugin() {
  local src dest
  src="$(install_src_dir)"
  dest="$HERDR_PLUGIN_DIR"
  if [[ -d "$src/plugins/dev-layout" ]]; then
    deploy_tree "$src/plugins/dev-layout" "$dest"
  else
    ensure_dir "$dest"
    deploy_install_file "plugins/dev-layout/herdr-plugin.toml" "$dest/herdr-plugin.toml"
    deploy_install_file "plugins/dev-layout/dev-layout.sh" "$dest/dev-layout.sh"
  fi
  run chmod +x "$dest/dev-layout.sh" 2>/dev/null || true

  if command -v herdr >/dev/null 2>&1; then
    info "linking herdr plugin: $PLUGIN_ID"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "[dry-run] herdr plugin link $dest"
    else
      herdr plugin link "$dest" 2>/dev/null || herdr plugin link "$dest" || warn "herdr plugin link failed — run manually: herdr plugin link $dest"
    fi
  else
    warn "herdr not on PATH — plugin copied but not linked"
  fi
}

deploy_finalize_permissions() {
  run chmod +x "$LOCAL_BIN/agentic-dev" \
    "$WORKTRUNK_CONFIG_DIR/herdr-layout.sh" \
    "$AGENTIC_DEV_SHELL_DIR/agentic-dev.sh" \
    "$AGENTIC_DEV_SHELL_DIR/agentic-dev.zsh" \
    "$AGENTIC_DEV_SHELL_DIR/agentic-dev.inc.sh" \
    "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh" 2>/dev/null || true
  find "${HOME}/.local/share/agentic-dev/lib" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
}

deploy_configs() {
  local -a files=(
    "config/shell/agentic-dev.inc.sh|${AGENTIC_DEV_SHELL_DIR}/agentic-dev.inc.sh"
    "config/bash/agentic-dev.sh|${AGENTIC_DEV_SHELL_DIR}/agentic-dev.sh"
    "config/zsh/agentic-dev.zsh|${AGENTIC_DEV_SHELL_DIR}/agentic-dev.zsh"
    "config/herdr/config.toml|${HERDR_CONFIG_DIR}/config.toml"
    "config/worktrunk/herdr-layout.sh|${WORKTRUNK_CONFIG_DIR}/herdr-layout.sh"
    "bin/agentic-dev|${LOCAL_BIN}/agentic-dev"
  )
  local entry rel dest

  prompt_agent_command

  ensure_dir "$AGENTIC_DEV_CONFIG_DIR"
  ensure_dir "$AGENTIC_DEV_SHELL_DIR"
  ensure_dir "$HERDR_CONFIG_DIR"
  ensure_dir "$WORKTRUNK_CONFIG_DIR"
  ensure_dir "${HOME}/.local/share/agentic-dev"

  for entry in "${files[@]}"; do
    rel="${entry%%|*}"
    dest="${entry#*|}"
    deploy_install_file "$rel" "$dest"
  done

  deploy_agentic_dev_config
  deploy_lib
  deploy_plugin

  if [[ ! -f "$WORKTRUNK_CONFIG_DIR/config.toml" ]] || [[ "$FORCE" -eq 1 ]]; then
    deploy_install_file "config/worktrunk/config.toml" "$WORKTRUNK_CONFIG_DIR/config.toml"
  else
    info "keeping existing worktrunk config: $WORKTRUNK_CONFIG_DIR/config.toml"
  fi

  deploy_finalize_permissions
}
