#!/usr/bin/env bash
# shellcheck shell=bash

show_help() {
  cat <<EOF
agentic-dev-setup v${AGENTIC_DEV_VERSION}

Install:
  curl -fsSL https://setup.simoncrypta.dev/install.sh | bash
  curl -fsSL https://setup.simoncrypta.dev/install.sh | bash -s -- --yes

install.sh options:
  -h, --help   Show this help
  -y, --yes    Non-interactive (skip agent prompt; use existing/default config)

Post-install CLI (agentic-dev):
  help          This help
  doctor        Check dependencies and integration
  update        Re-sync configs from latest release
  reconfigure   Re-prompt agent command
  dry-run       Show planned actions without changes
  uninstall     Remove marker block and managed files

Shell commands:
  dev           Dev layout for current directory (attach or switch workspace)
  wtc [branch]  Create worktree + new Herdr workspace
  wts [branch]  Switch to existing worktree (fzf if no branch)
  wtd [branch]  Remove worktree + close Herdr workspace
  d             Apply dev layout in current Herdr workspace
  t             Launch herdr

Layout:
  Left 50%: agent pane (sticky) — command from ~/.config/agentic-dev/config.toml
  Tabs: review (tuicr), explorer (nvim), terminal (shell)

Herdr keys (prefix = Ctrl-Space):
  prefix+D      Apply dev layout in current workspace
  prefix+1      Focus agent pane (recreates if crashed)
  prefix+2/3/4  review / explorer / terminal
  Alt+1/2/3     review / explorer / terminal
  Ctrl+Alt+HJKL Focus panes left/down/up/right
  prefix+q      Reload herdr config

Tab switching works without a healthy agent pane. The agent is recreated lazily on
the next tab switch or prefix+1.

Omarchy / Linux:
  Clears fcitx5 Ctrl+Alt+H/J spell-hint hotkeys (conflicts with pane focus)
  Optionally patches Hyprland SUPER+ALT+RETURN to launch herdr

Config:
  ~/.config/agentic-dev/config.toml      agent command + editor
  ~/.config/herdr/config.toml            keybindings + plugin actions
  ~/.config/herdr/plugins/dev-layout/    dev layout plugin
  ~/.config/worktrunk/herdr-layout.sh
  ~/.config/worktrunk/config.toml        worktrunk hooks
  ~/.config/fcitx5/conf/keyboard.conf    Linux fcitx5 hint trigger override

Plugin install from GitHub (alternative):
  herdr plugin install <owner>/agentic-dev-setup/plugins/dev-layout
EOF
}

show_summary() {
  log ""
  log "agentic-dev-setup installed (v${AGENTIC_DEV_VERSION})"
  log ""
  log "Agent command: $(read_agent_command 2>/dev/null || echo agent)"
  log "Config: ${AGENTIC_DEV_USER_CONFIG}"
  log ""
  log "Try: dev"
  log "Help: agentic-dev help"
  log ""
}
