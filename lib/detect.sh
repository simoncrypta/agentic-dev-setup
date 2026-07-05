#!/usr/bin/env bash
# shellcheck shell=bash

detect_os() {
  case "$(uname -s)" in
    Darwin) printf 'macos' ;;
    Linux) printf 'linux' ;;
    *) printf 'unknown' ;;
  esac
}

detect_arch() {
  uname -m
}

detect_shell_name() {
  basename "${SHELL:-/bin/bash}"
}

is_omarchy() {
  [[ -d "${HOME}/.local/share/omarchy" ]]
}

has_brew() {
  command -v brew >/dev/null 2>&1
}

brew_shellenv_snippet() {
  if [[ -x /opt/homebrew/bin/brew ]]; then
    printf '%s\n' 'eval "$(/opt/homebrew/bin/brew shellenv)"'
  elif [[ -x /usr/local/bin/brew ]]; then
    printf '%s\n' 'eval "$(/usr/local/bin/brew shellenv)"'
  elif [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    printf '%s\n' 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'
  fi
}

has_marker_block() {
  local file="$1"
  [[ -f "$file" ]] && grep -qF "$AGENTIC_DEV_MARKER_START" "$file"
}

shell_rc_for() {
  local shell_name="$1"
  case "$shell_name" in
    zsh) printf '%s' "${HOME}/.zshrc" ;;
    bash) printf '%s' "${HOME}/.bashrc" ;;
    *) printf '%s' "${HOME}/.${shell_name}rc" ;;
  esac
}

detect_conflicts() {
  local rc="$1"
  [[ -f "$rc" ]] || return 0
  local conflicts=()
  if grep -qE 'worktree-dev\(\)|function worktree-dev' "$rc" \
    && ! grep -qF "$AGENTIC_DEV_MARKER_START" "$rc"; then
    conflicts+=("existing worktree-dev() outside agentic-dev marker")
  fi
  if grep -q 'source.*herdr-layout\.sh' "$rc" \
    && ! grep -qF "$AGENTIC_DEV_MARKER_START" "$rc"; then
    conflicts+=("existing herdr-layout.sh source outside agentic-dev marker")
  fi
  if ((${#conflicts[@]} > 0)); then
    printf '%s\n' "${conflicts[@]}"
    return 1
  fi
  return 0
}

doctor_omarchy_integration() {
  local missing=0
  if [[ "$(detect_os)" != "linux" ]]; then
    return 0
  fi
  if is_omarchy || command -v fcitx5 >/dev/null 2>&1; then
    if [[ -f "${FCITX5_CONFIG_DIR}/conf/keyboard.conf" ]] \
      && grep -q '^Hint Trigger=$' "${FCITX5_CONFIG_DIR}/conf/keyboard.conf" 2>/dev/null; then
      log "  ok  fcitx5 keyboard.conf (hint triggers cleared)"
    else
      log "  missing  fcitx5 keyboard.conf hint trigger override"
      missing=$((missing + 1))
    fi
  fi
  if is_omarchy; then
    if [[ -f "${HOME}/.config/hypr/bindings.conf" ]] \
      && grep -qE 'Herdr|herdr' "${HOME}/.config/hypr/bindings.conf" 2>/dev/null; then
      log "  ok  hypr bindings include herdr"
    else
      log "  missing  hypr SUPER+ALT+RETURN herdr binding"
      missing=$((missing + 1))
    fi
  fi
  return "$missing"
}

doctor_plugin() {
  if ! command -v herdr >/dev/null 2>&1; then
    log "  missing  herdr (cannot check plugin)"
    return 1
  fi
  if herdr plugin list 2>/dev/null | grep -qF "$PLUGIN_ID"; then
    log "  ok  plugin $PLUGIN_ID linked"
    return 0
  fi
  log "  missing  plugin $PLUGIN_ID"
  return 1
}
