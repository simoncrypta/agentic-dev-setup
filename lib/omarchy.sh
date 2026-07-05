#!/usr/bin/env bash
# shellcheck shell=bash

HYPR_BINDINGS="${HOME}/.config/hypr/bindings.conf"
HERDR_HYPR_BINDING='bindd = SUPER ALT, RETURN, Herdr, exec, uwsm-app -- xdg-terminal-exec --dir="$(omarchy-cmd-terminal-cwd)" herdr'

deploy_fcitx5_keyboard_conf() {
  [[ "$(detect_os)" == "linux" ]] || return 0
  if ! is_omarchy && ! command -v fcitx5 >/dev/null 2>&1; then
    info "skipping fcitx5 (not installed)"
    return 0
  fi

  deploy_install_file "config/fcitx5/conf/keyboard.conf" "${FCITX5_CONFIG_DIR}/conf/keyboard.conf"
  restart_fcitx5
}

restart_fcitx5() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] restart fcitx5"
    return 0
  fi
  if command -v omarchy-restart-app >/dev/null 2>&1; then
    info "restarting fcitx5 via omarchy-restart-app"
    omarchy-restart-app fcitx5 --disable notificationitem 2>/dev/null || true
    return 0
  fi
  if command -v fcitx5 >/dev/null 2>&1; then
    info "restarting fcitx5"
    pkill -x fcitx5 2>/dev/null || true
    if command -v uwsm-app >/dev/null 2>&1; then
      uwsm-app -- fcitx5 --disable notificationitem &
    else
      fcitx5 --disable notificationitem &
    fi
  fi
}

hypr_has_herdr_binding() {
  [[ -f "$HYPR_BINDINGS" ]] || return 1
  grep -qE 'Herdr|herdr' "$HYPR_BINDINGS" 2>/dev/null
}

patch_hypr_herdr_binding() {
  [[ -f "$HYPR_BINDINGS" ]] || {
    warn "hypr bindings not found: $HYPR_BINDINGS"
    return 1
  }

  if hypr_has_herdr_binding; then
    info "hypr already has herdr binding — skipping"
    return 0
  fi

  if ! confirm "Patch ~/.config/hypr/bindings.conf to launch herdr on SUPER+ALT+RETURN?"; then
    info "skipping hypr binding patch"
    return 0
  fi

  info "patching hypr bindings for herdr"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would update $HYPR_BINDINGS"
    return 0
  fi

  local tmp replaced=0
  tmp="$(mktemp)"
  while IFS= read -r line; do
    if [[ "$line" =~ SUPER[[:space:]]+ALT,[[:space:]]+RETURN ]] \
      && [[ "$line" =~ tmux|Tmux ]]; then
      printf '%s\n' "$HERDR_HYPR_BINDING"
      replaced=1
    else
      printf '%s\n' "$line"
    fi
  done <"$HYPR_BINDINGS" >"$tmp"

  if [[ "$replaced" -eq 0 ]]; then
    printf '\n%s\n' "$HERDR_HYPR_BINDING" >>"$tmp"
  fi

  mv "$tmp" "$HYPR_BINDINGS"
  info "hypr bindings updated — reload Hyprland config to apply"
}

deploy_omarchy_integration() {
  deploy_fcitx5_keyboard_conf

  if is_omarchy; then
    patch_hypr_herdr_binding
  fi
}
