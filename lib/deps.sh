#!/usr/bin/env bash
# shellcheck shell=bash

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

install_herdr_binary() {
  if dep_present herdr; then
    info "present: herdr"
    return 0
  fi
  if has_brew; then
    info "installing via brew: herdr"
    if run brew install herdr && dep_present herdr; then
      return 0
    fi
    warn "brew install herdr failed — trying herdr.dev installer"
  fi
  dep_present curl || maybe_apt_install curl curl || maybe_pacman_install curl curl || true
  info "installing via https://herdr.dev/install.sh"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  curl -fsSL https://herdr.dev/install.sh | sh
  dep_present herdr || warn "herdr install may have succeeded but herdr is not on PATH"
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

  install_herdr_binary || warn "missing herdr"
  install_dep git git git git || true
  install_worktrunk_binary || true
  install_dep fzf fzf fzf fzf || true
  install_dep jq jq jq jq || true
  install_tuicr_binary || warn "missing tuicr (review tab needs it)"
  install_dep nvim neovim neovim neovim || true
  install_dep lazygit lazygit lazygit lazygit || true
}

doctor_dependencies() {
  local missing=0
  for cmd in herdr git wt fzf jq tuicr nvim lazygit; do
    if dep_present "$cmd"; then
      log "  ok  $cmd ($(command -v "$cmd"))"
    else
      log "  missing  $cmd"
      missing=$((missing + 1))
    fi
  done
  return "$missing"
}
