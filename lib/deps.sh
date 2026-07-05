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
    warn "missing $pkg (install brew or $pkg manually)"
    return 1
  fi
  info "installing via brew: $pkg"
  run brew install "$pkg"
}

maybe_pacman_install() {
  local pkg="$1"
  if dep_present "$pkg"; then
    info "present: $pkg"
    return 0
  fi
  if ! command -v pacman >/dev/null 2>&1; then
    return 1
  fi
  info "installing via pacman: $pkg"
  run sudo pacman -S --needed --noconfirm "$pkg"
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

install_dependencies() {
  info "checking dependencies..."

  install_herdr_binary || warn "missing herdr"
  dep_present git || warn "missing git (required for worktrees)"

  install_worktrunk_binary || true
  maybe_brew_install fzf || maybe_pacman_install fzf || warn "missing fzf (wts picker needs it)"
  maybe_brew_install jq || maybe_pacman_install jq || warn "missing jq (worktree commands need it)"
  maybe_brew_install tuicr || warn "missing tuicr (review tab needs it)"
  maybe_brew_install nvim || maybe_pacman_install neovim || warn "missing nvim (explorer tab needs it)"
  maybe_brew_install lazygit || maybe_pacman_install lazygit || warn "missing lazygit (git UI in explorer tab)"
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
