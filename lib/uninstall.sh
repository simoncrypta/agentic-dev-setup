#!/usr/bin/env bash
# shellcheck shell=bash

uninstall_agentic_dev() {
  info "uninstalling agentic-dev-setup..."

  remove_marker_block "$(shell_rc_for bash)"
  remove_marker_block "$(shell_rc_for zsh)"

  if [[ -e "$LOCAL_BIN/agentic-dev" ]]; then
    info "remove: $LOCAL_BIN/agentic-dev"
    run rm -f "$LOCAL_BIN/agentic-dev"
  fi

  if [[ -d "${HOME}/.local/share/agentic-dev" ]]; then
    info "remove: ${HOME}/.local/share/agentic-dev"
    run rm -rf "${HOME}/.local/share/agentic-dev"
  fi

  if confirm "Remove ~/.config/agentic-dev (includes config.toml)?"; then
    if [[ -e "$AGENTIC_DEV_CONFIG_DIR" ]]; then
      info "remove: $AGENTIC_DEV_CONFIG_DIR"
      run rm -rf "$AGENTIC_DEV_CONFIG_DIR"
    fi
  else
    info "keeping user config: $AGENTIC_DEV_USER_CONFIG"
    run rm -rf "$AGENTIC_DEV_SHELL_DIR"
    run rm -f "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh"
  fi

  if command -v herdr >/dev/null 2>&1; then
    if confirm "Unlink Herdr plugin $PLUGIN_ID?"; then
      run herdr plugin unlink "$PLUGIN_ID" 2>/dev/null || true
    fi
  fi

  if confirm "Also remove herdr config, plugin files, and worktrunk configs we installed?"; then
    run rm -f "$HERDR_CONFIG_DIR/config.toml"
    run rm -rf "$HERDR_PLUGIN_DIR"
    run rm -f "$WORKTRUNK_CONFIG_DIR/herdr-layout.sh"
    if confirm "Remove worktrunk config.toml hooks too?"; then
      run rm -f "$WORKTRUNK_CONFIG_DIR/config.toml"
    fi
  fi

  if confirm "Remove fcitx5 keyboard.conf override?"; then
    run rm -f "${FCITX5_CONFIG_DIR}/conf/keyboard.conf"
  fi

  log "uninstall complete"
}
