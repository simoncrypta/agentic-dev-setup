#!/usr/bin/env bash
# shellcheck shell=bash

HERDR_MIN_VERSION=0.7.5

dep_present() {
  command -v "$1" >/dev/null 2>&1
}

maybe_brew_install() {
  local pkg="$1"
  if dep_present "$pkg"; then
    info "present: $pkg"
    return 0
  fi
  if ! has_brew; then
    return 1
  fi
  info "installing via brew: $pkg"
  run brew install "$pkg"
}

maybe_pacman_install() {
  local pkg="$1"
  local bin="${2:-$1}"
  if dep_present "$bin"; then
    info "present: $bin"
    return 0
  fi
  if ! command -v pacman >/dev/null 2>&1; then
    return 1
  fi
  info "installing via pacman: $pkg"
  run sudo pacman -S --needed --noconfirm "$pkg"
}

maybe_apt_install() {
  local pkg="$1"
  local bin="${2:-$1}"
  if dep_present "$bin"; then
    info "present: $bin"
    return 0
  fi
  if ! has_apt; then
    return 1
  fi
  info "installing via apt: $pkg"
  run sudo apt-get install -y "$pkg"
}

install_dep() {
  local bin="$1" brew_spec="${2:-$1}" apt_pkg="${3:-$1}" pacman_pkg="${4:-$1}"
  if dep_present "$bin"; then
    info "present: $bin"
    return 0
  fi
  if has_brew; then
    info "installing via brew: $brew_spec"
    if run brew install "$brew_spec" && dep_present "$bin"; then
      return 0
    fi
  fi
  maybe_apt_install "$apt_pkg" "$bin" && return 0
  maybe_pacman_install "$pacman_pkg" "$bin" && return 0
  warn "missing $bin (install brew, apt, or pacman package manually)"
  return 1
}

herdr_version_at_least() {
  local current="$1" required="$2"
  local current_major current_minor current_patch
  local required_major required_minor required_patch

  [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 2
  [[ "$required" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 2

  IFS=. read -r current_major current_minor current_patch <<<"$current"
  IFS=. read -r required_major required_minor required_patch <<<"$required"

  ((10#$current_major > 10#$required_major)) && return 0
  ((10#$current_major < 10#$required_major)) && return 1
  ((10#$current_minor > 10#$required_minor)) && return 0
  ((10#$current_minor < 10#$required_minor)) && return 1
  ((10#$current_patch >= 10#$required_patch))
}

herdr_parse_version() {
  local output="$1" token
  local -a tokens
  output="${output//$'\n'/ }"
  IFS=$' \t\r\n' read -r -a tokens <<<"$output"
  for token in "${tokens[@]}"; do
    token="${token#v}"
    if [[ "$token" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s\n' "$token"
      return 0
    fi
  done
  return 2
}

herdr_version_output() {
  local herdr_path output_file pid rc
  local elapsed=0 grace_elapsed=0
  local timeout_seconds="${HERDR_VERSION_TIMEOUT_SECONDS:-5}"
  local term_grace_tenths="${HERDR_VERSION_TERM_GRACE_TENTHS:-10}"

  herdr_path="$(command -v herdr)" || return 127
  output_file="$(mktemp)"
  "$herdr_path" --version >"$output_file" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if ((elapsed >= timeout_seconds * 10)); then
      kill -TERM "$pid" 2>/dev/null || true
      while kill -0 "$pid" 2>/dev/null && ((grace_elapsed < term_grace_tenths)); do
        sleep 0.1
        grace_elapsed=$((grace_elapsed + 1))
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
      wait "$pid" 2>/dev/null || true
      rm -f "$output_file"
      return 124
    fi
    sleep 0.1
    elapsed=$((elapsed + 1))
  done
  if wait "$pid"; then
    rc=0
  else
    rc=$?
  fi
  cat "$output_file"
  rm -f "$output_file"
  return "$rc"
}

herdr_installed_version() {
  local output rc
  if output="$(herdr_version_output)"; then
    herdr_parse_version "$output"
    return $?
  else
    rc=$?
    return "$rc"
  fi
}

herdr_install_manager() {
  local herdr_path link_target updater_dir
  herdr_path="$(command -v herdr)"
  link_target="$(readlink "$herdr_path" 2>/dev/null || true)"

  case "$herdr_path $link_target" in
    *'/nix/store/'*|*'/.nix-profile/'*) printf 'nix\n'; return 0 ;;
    *'/.local/share/mise/'*|*'/.mise/'*) printf 'mise\n'; return 0 ;;
    *'/Homebrew/'*|*'/homebrew/'*|*'/linuxbrew/'*|*'/Cellar/'*) printf 'brew\n'; return 0 ;;
  esac

  updater_dir="${HERDR_INSTALL_DIR:-$HOME/.local/bin}"
  if [[ "$herdr_path" == "$updater_dir/herdr" ]]; then
    printf 'updater\n'
  else
    printf 'manual\n'
  fi
}

herdr_upgrade_command() {
  case "$1" in
    brew) printf 'brew upgrade herdr\n' ;;
    mise) printf 'mise use -g herdr\n' ;;
    nix) printf 'nix profile upgrade <index-or-name>\n' ;;
    updater) printf 'herdr update --handoff\n' ;;
    *) printf 'reinstall Herdr >=%s using the method that owns %s\n' \
      "$HERDR_MIN_VERSION" "$(command -v herdr)" ;;
  esac
}

require_herdr_min_version() {
  local found manager command
  if ! found="$(herdr_installed_version)"; then
    warn "cannot determine Herdr version (required >=$HERDR_MIN_VERSION)"
    return 1
  fi
  if herdr_version_at_least "$found" "$HERDR_MIN_VERSION"; then
    info "present: herdr $found (required >=$HERDR_MIN_VERSION)"
    return 0
  fi

  manager="$(herdr_install_manager)"
  command="$(herdr_upgrade_command "$manager")"
  if [[ "$manager" != updater ]]; then
    warn "Herdr $found is below required >=$HERDR_MIN_VERSION; run: $command"
    return 1
  fi

  info "updating Herdr $found to >=$HERDR_MIN_VERSION with live handoff"
  if ! run "$(command -v herdr)" update --handoff; then
    warn "Herdr update failed; run: $command"
    return 1
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  if ! found="$(herdr_installed_version)"; then
    warn "Herdr update reported success but its version is unreadable; run: $command"
    return 1
  fi
  if ! herdr_version_at_least "$found" "$HERDR_MIN_VERSION"; then
    warn "Herdr update reported success but found $found; required >=$HERDR_MIN_VERSION; run: $command"
    return 1
  fi
  info "updated: herdr $found (required >=$HERDR_MIN_VERSION)"
}

install_herdr_binary() {
  if dep_present herdr; then
    require_herdr_min_version
    return $?
  fi
  if has_brew; then
    info "installing via brew: herdr"
    if run brew install herdr && dep_present herdr; then
      require_herdr_min_version
      return $?
    fi
    warn "brew install herdr failed — trying herdr.dev installer"
  fi
  dep_present curl || maybe_apt_install curl curl || maybe_pacman_install curl curl || true
  info "installing via https://herdr.dev/install.sh"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  curl -fsSL https://herdr.dev/install.sh | sh
  if ! dep_present herdr; then
    warn "herdr install may have succeeded but herdr is not on PATH"
    return 1
  fi
  require_herdr_min_version
}

install_worktrunk_binary() {
  if dep_present wt; then
    info "present: wt"
    return 0
  fi
  if has_brew; then
    info "installing via brew: worktrunk"
    if run brew install worktrunk && dep_present wt; then
      return 0
    fi
    warn "brew install worktrunk failed — trying GitHub release"
  fi
  local os arch url dest
  os="$(detect_os)"
  arch="$(detect_arch)"
  case "$os-$arch" in
    linux-x86_64|linux-amd64)
      url="https://github.com/max-sixty/worktrunk/releases/latest/download/worktrunk-x86_64-unknown-linux-gnu.tar.gz"
      ;;
    linux-aarch64|linux-arm64)
      url="https://github.com/max-sixty/worktrunk/releases/latest/download/worktrunk-aarch64-unknown-linux-gnu.tar.gz"
      ;;
    macos-x86_64|macos-amd64)
      url="https://github.com/max-sixty/worktrunk/releases/latest/download/worktrunk-x86_64-apple-darwin.tar.gz"
      ;;
    macos-arm64|macos-aarch64)
      url="https://github.com/max-sixty/worktrunk/releases/latest/download/worktrunk-aarch64-apple-darwin.tar.gz"
      ;;
    *)
      warn "cannot auto-install worktrunk on $os/$arch — install wt manually"
      return 1
      ;;
  esac
  dest="${LOCAL_BIN}/wt"
  ensure_dir "$LOCAL_BIN"
  dep_present curl || maybe_apt_install curl curl || true
  info "downloading worktrunk from GitHub releases"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "$url" | tar -xz -C "$tmp"
  if [[ -f "$tmp/wt" ]]; then
    install -m 0755 "$tmp/wt" "$dest"
  elif [[ -f "$tmp/worktrunk" ]]; then
    install -m 0755 "$tmp/worktrunk" "$dest"
  else
    warn "worktrunk archive layout unexpected — install wt manually"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
}

install_tuicr_binary() {
  if dep_present tuicr; then
    info "present: tuicr"
    return 0
  fi
  if has_brew; then
    info "installing via brew: agavra/tap/tuicr"
    if run brew install agavra/tap/tuicr && dep_present tuicr; then
      return 0
    fi
    warn "brew install tuicr failed — trying GitHub release"
  fi
  local os arch pattern url dest tmp
  os="$(detect_os)"
  arch="$(detect_arch)"
  case "$os-$arch" in
    linux-x86_64|linux-amd64)
      pattern='x86_64-unknown-linux-gnu'
      ;;
    linux-aarch64|linux-arm64)
      pattern='aarch64-unknown-linux-gnu'
      ;;
    macos-x86_64|macos-amd64)
      pattern='x86_64-apple-darwin'
      ;;
    macos-arm64|macos-aarch64)
      pattern='aarch64-apple-darwin'
      ;;
    *)
      warn "cannot auto-install tuicr on $os/$arch — install tuicr manually"
      return 1
      ;;
  esac
  dep_present curl || maybe_apt_install curl curl || true
  dep_present jq || maybe_apt_install jq jq || true
  url="$(curl -fsSL https://api.github.com/repos/agavra/tuicr/releases/latest \
    | jq -r --arg pat "$pattern" '.assets[] | select(.name | contains($pat)) | .browser_download_url' \
    | head -1)"
  if [[ -z "$url" || "$url" == "null" ]]; then
    warn "could not resolve tuicr release URL — install tuicr manually"
    return 1
  fi
  dest="${LOCAL_BIN}/tuicr"
  ensure_dir "$LOCAL_BIN"
  info "downloading tuicr from GitHub releases"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  tmp="$(mktemp -d)"
  curl -fsSL "$url" | tar -xz -C "$tmp"
  if [[ -f "$tmp/tuicr" ]]; then
    install -m 0755 "$tmp/tuicr" "$dest"
  else
    warn "tuicr archive layout unexpected — install tuicr manually"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
}

install_dependencies() {
  info "checking dependencies..."

  install_herdr_binary || {
    warn "Herdr >=$HERDR_MIN_VERSION is required"
    return 1
  }
  install_dep git git git git || true
  install_worktrunk_binary || true
  install_dep fzf fzf fzf fzf || true
  install_dep jq jq jq jq || true
  install_tuicr_binary || warn "missing tuicr (review tab needs it)"
  install_dep nvim neovim neovim neovim || true
  install_dep lazygit lazygit lazygit lazygit || true
}

doctor_dependencies() {
  local missing=0 found path output rc
  for cmd in herdr git wt fzf jq tuicr nvim lazygit; do
    if [[ "$cmd" == herdr ]] && dep_present herdr; then
      path="$(command -v herdr)"
      if output="$(herdr_version_output)"; then
        if found="$(herdr_parse_version "$output")"; then
          if herdr_version_at_least "$found" "$HERDR_MIN_VERSION"; then
            log "  ok  herdr ($path; found $found, required >=$HERDR_MIN_VERSION)"
          else
            log "  outdated  herdr ($path; found $found, required >=$HERDR_MIN_VERSION)"
            missing=$((missing + 1))
          fi
        else
          log "  invalid  herdr ($path; found unrecognized output, required >=$HERDR_MIN_VERSION)"
          missing=$((missing + 1))
        fi
      else
        rc=$?
        if [[ "$rc" -eq 124 ]]; then
          found="timeout"
        else
          found="unavailable"
        fi
        log "  invalid  herdr ($path; found $found, required >=$HERDR_MIN_VERSION)"
        missing=$((missing + 1))
      fi
    elif dep_present "$cmd"; then
      log "  ok  $cmd ($(command -v "$cmd"))"
    else
      log "  missing  $cmd"
      missing=$((missing + 1))
    fi
  done
  return "$missing"
}
