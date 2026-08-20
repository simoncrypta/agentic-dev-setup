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
  -y, --yes    Non-interactive (skip layout prompts; use existing/default config)

Post-install CLI (agentic-dev):
  help          This help
  doctor        Check dependencies and integration
  update        Re-sync configs, helper, and skill from the install source
  reconfigure   Re-prompt agent / review / explorer commands (does not re-sync the helper)
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
  Tabs: review (tuicr or hunk), explorer (nvim / nano / tode / fresh), terminal (shell)

Herdr keys (prefix = Ctrl-Space):
  prefix+D           Apply dev layout in current workspace
  prefix+1           Focus agent pane (recreates if crashed)
  prefix+2/3/4       review / explorer / terminal
  Alt+1/2/3          Same tabs in a dev workspace; else tab 1/2/3
  Ctrl+Alt+HJKL      Focus panes left/down/up/right
  Alt+Left/Right     Previous/next tab
  Alt+Up/Down        Previous/next workspace
  prefix+w           Workspace picker
  prefix+shift+k     Close workspace
  prefix+shift+g/c/r Worktree open / open-current / remove
  prefix+q           Reload herdr config
  prefix+shift+q     Detach

Tab switching works without a healthy agent pane. The agent is recreated lazily on
the next tab switch or prefix+1.

Omarchy / Linux:
  Clears fcitx5 Ctrl+Alt+H/J spell-hint hotkeys when fcitx5 is present
  Optionally patches Hyprland SUPER+ALT+RETURN to launch herdr
  Quattro: ~/.config/hypr/bindings.lua with { omarchy = "terminal-herdr" }
  Native Omarchy Herdr is SUPER+CTRL+RETURN; packages via omarchy pkg add

Install order:
  mise first (herdr, worktrunk, fzf, jq, lazygit, grok, hunk)
  then omarchy pkg add on Omarchy, then brew / apt / pacman / upstream
  selected review/explorer tools only (tuicr or hunk; nvim / nano / tode / fresh)

Ubuntu / Debian:
  Uses apt for git, fzf, jq, neovim, lazygit, curl when mise is unavailable
  Downloads herdr, worktrunk, and selected review/explorer tools from upstream when needed

Config:
  ~/.config/agentic-dev/config.toml      agent, review, and explorer commands
  ~/.config/herdr/config.toml            keybindings + plugin actions
  ~/.config/herdr/plugins/dev-layout/    dev layout plugin
  ~/.config/worktrunk/herdr-layout.sh
  ~/.config/worktrunk/config.toml        worktrunk hooks
  ~/.agents/skills/handoff/              handoff skill (canonical)
  ~/.config/fcitx5/conf/keyboard.conf    Linux fcitx5 hint trigger override

Agent skill (`handoff`):
  Installed to ~/.agents/skills/handoff (https://agentskills.io). Extra symlink
  only for grok/pi/codex/opencode/claude. cursor (`agent`) uses ~/.agents/skills.
  Source: skills/handoff/.
  Manual: npx skills add simoncrypta/agentic-dev-setup -s handoff -g

Plugin only (see README — review manifest/scripts before install):
  herdr plugin install simoncrypta/agentic-dev-setup/plugins/dev-layout
  herdr plugin install simoncrypta/agentic-dev-setup/plugins/dev-layout --ref v0.1.1
  herdr plugin link /path/to/agentic-dev-setup/plugins/dev-layout
  herdr plugin config-dir agentic-dev.dev-layout
  herdr plugin action invoke agentic-dev.dev-layout.create
EOF
}

show_summary() {
  log ""
  log "agentic-dev-setup installed (v${AGENTIC_DEV_VERSION})"
  log ""
  log "Agent command: $(read_agent_command 2>/dev/null || echo agent)"
  log "Review command: $(read_layout_review 2>/dev/null || echo tuicr)"
  log "Explorer command: $(read_layout_editor 2>/dev/null || echo nvim)"
  log "Config: ${AGENTIC_DEV_USER_CONFIG}"
  log "Skill: ${AGENTIC_DEV_SKILL_DIR}"
  log ""
  log "Try: dev"
  log "Help: agentic-dev help"
  log ""
}
