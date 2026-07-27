#!/usr/bin/env bash
# shellcheck shell=bash

detect_os() {
  case "$(uname -s)" in
    Darwin) printf 'macos' ;;
    Linux) printf 'linux' ;;
    *) printf 'unknown' ;;
  esac
}

detect_linux_distro() {
  [[ "$(detect_os)" == "linux" ]] || return 0
  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    case "${ID:-}" in
      ubuntu) printf 'ubuntu' ;;
      debian) printf 'debian' ;;
      arch) printf 'arch' ;;
      *) printf '%s' "${ID:-linux}" ;;
    esac
    return 0
  fi
  printf 'unknown'
}

detect_platform() {
  local os distro
  os="$(detect_os)"
  if [[ "$os" == "linux" ]]; then
    distro="$(detect_linux_distro)"
    printf '%s/%s/%s' "$os" "$distro" "$(detect_arch)"
    return 0
  fi
  printf '%s/%s' "$os" "$(detect_arch)"
}

is_ubuntu() {
  [[ "$(detect_linux_distro)" == "ubuntu" ]]
}

is_debian() {
  [[ "$(detect_linux_distro)" == "debian" ]]
}

has_apt() {
  command -v apt-get >/dev/null 2>&1
}

has_hyprland() {
  [[ -f "${HOME}/.config/hypr/hyprland.conf" \
    || -f "${HOME}/.config/hypr/bindings.conf" ]]
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
  if is_omarchy || has_hyprland; then
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
  local missing=0
  if ! command -v herdr >/dev/null 2>&1; then
    log "  missing  herdr (cannot check plugin)"
    return 1
  fi

  if ! plugin_inspect "$PLUGIN_ID"; then
    log "  invalid  plugin $PLUGIN_ID registry/list entry is ambiguous or malformed"
    missing=$((missing + 1))
  elif plugin_is_exact_local "$HERDR_DEV_LAYOUT_LEGACY_DIR"; then
    if [[ -d "$HERDR_DEV_LAYOUT_LEGACY_DIR" ]]; then
      log "  ok  plugin $PLUGIN_ID [local:$HERDR_DEV_LAYOUT_LEGACY_DIR] (legacy)"
    else
      log "  stale  plugin $PLUGIN_ID source directory is missing: $HERDR_DEV_LAYOUT_LEGACY_DIR"
      missing=$((missing + 1))
    fi
  elif plugin_is_exact_github "$DEV_LAYOUT_PLUGIN_REPO" "$DEV_LAYOUT_PLUGIN_REF"; then
    log "  ok  plugin $PLUGIN_ID [github:$DEV_LAYOUT_PLUGIN_REPO@$DEV_LAYOUT_PLUGIN_REF]"
  elif [[ "$PLUGIN_STATUS" == "missing" ]]; then
    log "  missing  plugin $PLUGIN_ID"
    missing=$((missing + 1))
  else
    log "  mismatched  plugin $PLUGIN_ID preserved [${PLUGIN_SOURCE_RAW#- }]"
    missing=$((missing + 1))
  fi

  doctor_adopted_plugin pickr "$PICKR_PLUGIN_REPO" "$PICKR_PLUGIN_REF" || missing=$((missing + 1))
  doctor_adopted_plugin worktrunk "$WORKTRUNK_PLUGIN_REPO" "$WORKTRUNK_PLUGIN_REF" || missing=$((missing + 1))
  [[ "$missing" -eq 0 ]]
}

doctor_adopted_plugin() {
  local id="$1" repo="$2" ref="$3"
  if ! plugin_inspect "$id"; then
    log "  invalid  third-party plugin $id registry/list entry is ambiguous or malformed"
    return 1
  fi
  if plugin_is_exact_github "$repo" "$ref"; then
    log "  ok  third-party plugin $id [github:$repo@$ref]"
    return 0
  fi
  if [[ "$PLUGIN_STATUS" == "missing" ]]; then
    log "  missing  third-party plugin $id"
    return 1
  fi
  log "  warning  third-party plugin $id is pre-existing and preserved [${PLUGIN_SOURCE_RAW#- }]"
  return 0
}
