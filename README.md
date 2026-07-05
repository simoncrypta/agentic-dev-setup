# agentic-dev-setup

Shareable Herdr + worktrunk dev layout for agentic coding workflows. Works on **Omarchy**, **Ubuntu/Debian**, and **macOS**.

Successor to [agentic-tmux-setup](https://github.com/simoncrypta/agentic-tmux-setup) — same sticky-agent layout, powered by [Herdr](https://herdr.dev) instead of tmux.

## Quick install

```bash
curl -fsSL https://setup.simoncrypta.dev/install.sh | bash
```

Non-interactive (skip agent prompt):

```bash
curl -fsSL https://setup.simoncrypta.dev/install.sh | bash -s -- --yes
```

From a local clone:

```bash
cd /path/to/agentic-dev-setup
./install.sh
```

## What you get

- **Herdr layout**: sticky agent pane (left) + tabs for review (`tuicr`), explorer (`nvim`), terminal
- **Dev layout plugin**: `agentic-dev.dev-layout` (linked automatically)
- **Shell commands**: `dev`, `wtc`, `wts`, `wtd`, `d`, `t`
- **worktrunk hooks**: auto-create/close Herdr workspaces on worktree start/remove
- **Config**: `~/.config/agentic-dev/config.toml` (agent command + editor)
- **Omarchy/Linux**: fcitx5 hint hotkeys cleared (`Ctrl+Alt+H/J`); optional Hyprland binding patch
- **Ubuntu/Debian**: apt installs for common deps; tuicr/herdr/worktrunk via GitHub when needed

### Layout

One Herdr workspace per worktree. The agent pane stays on the left (~50%); tool tabs are on the right. Switching tabs moves the agent pane with you — it is not its own tab.

```
┌──────────────────────────────────────────────────────────────────┐
│  workspace tabs   review   explorer   terminal      PREFIX  #h │
├─────────────────────────┬────────────────────────────────────────┤
│                         │                                        │
│   agent                 │   active tool tab                      │
│   (codex / claude /     │                                        │
│    agent / opencode)    │   review    → tuicr                    │
│                         │   explorer  → nvim (neo-tree)          │
│   sticky left pane      │   terminal  → shell                    │
│                         │                                        │
│   prefix+1              │   prefix+2/3/4  or  Alt+1/2/3          │
└─────────────────────────┴────────────────────────────────────────┘
```

Prefix is `Ctrl-Space`. `prefix+D` applies this layout in the current workspace.

### First-run prompt

On install you'll pick the agent pane command:

1. `agent`
2. `codex`
3. `opencode`
4. `claude`
5. custom

Saved to `~/.config/agentic-dev/config.toml`. Change later with `agentic-dev reconfigure`.

## Shell commands

| Command | Description |
|---------|-------------|
| `dev` | Dev layout for current directory |
| `wtc [branch]` | Create worktree + new Herdr workspace |
| `wts [branch]` | Switch to existing worktree (fzf picker) |
| `wtd [branch]` | Remove worktree + close Herdr workspace |
| `d` | Apply layout in current Herdr workspace |
| `t` | Launch herdr |

## Herdr keys

| Key | Action |
|-----|--------|
| `prefix+D` | Apply dev layout |
| `prefix+1` | Focus agent pane (recreates if crashed) |
| `prefix+2/3/4` | review / explorer / terminal |
| `Alt+1/2/3` | Same tabs without prefix |
| `Ctrl+Alt+H/J/K/L` | Focus pane left/down/up/right |
| `Alt+Up/Down` | Previous/next workspace |
| `prefix+q` | Reload herdr config |

Tab switching works even when the agent pane is missing — the agent is recreated lazily on the next tab switch or `prefix+1`.

## Post-install CLI

```bash
agentic-dev help         # full reference
agentic-dev doctor       # check deps + integration
agentic-dev update       # re-sync configs
agentic-dev reconfigure  # change agent command
agentic-dev dry-run      # preview changes
agentic-dev uninstall    # remove integration
```

## Omarchy / Linux notes

### Ubuntu / Debian

Dependencies install via **apt** when available:

```bash
sudo apt-get install -y git fzf jq neovim lazygit curl
```

Tools not in apt are fetched automatically:

- **herdr** — [herdr.dev/install.sh](https://herdr.dev/install.sh)
- **worktrunk** (`wt`) — GitHub release binary to `~/.local/bin`
- **tuicr** — GitHub release binary to `~/.local/bin`

Homebrew (Linuxbrew) is used when present and takes priority over apt.

On Ubuntu with **Hyprland**, the installer can optionally add `SUPER+ALT+RETURN` → `herdr` in `~/.config/hypr/bindings.conf`. If you use **fcitx5** (common on CJK setups), the `Ctrl+Alt+H/J` hint hotkey fix applies the same way as on Omarchy.

### fcitx5 `Ctrl+Alt+H` conflict

Omarchy runs fcitx5 for emoji and compose. By default fcitx5 binds `Ctrl+Alt+H/J` to spell-hint toggles, which conflicts with Herdr pane focus. This installer clears those hotkeys in `~/.config/fcitx5/conf/keyboard.conf`.

See [Omarchy discussion #1578](https://github.com/basecamp/omarchy/discussions/1578).

### Hyprland launcher

On Omarchy or any system with `~/.config/hypr/bindings.conf`, the installer can patch a key binding to launch `herdr` on `SUPER+ALT+RETURN` (replacing tmux if present). You'll be prompted during install.

Omarchy uses `uwsm-app` and `omarchy-cmd-terminal-cwd`; other Hyprland setups get a generic `xdg-terminal-exec herdr` binding.

## Dependencies

Installed only if missing (Homebrew, apt, pacman, or upstream installers):

- [herdr](https://herdr.dev) (brew, or `curl -fsSL https://herdr.dev/install.sh | sh`)
- git, worktrunk (`wt`), fzf, jq, tuicr, neovim, lazygit

## Files installed

```
~/.config/agentic-dev/config.toml
~/.config/agentic-dev/shell/agentic-dev.{sh,zsh,inc.sh}
~/.config/herdr/config.toml
~/.config/herdr/plugins/dev-layout/
~/.config/worktrunk/herdr-layout.sh
~/.config/worktrunk/config.toml   (only if not already present)
~/.config/fcitx5/conf/keyboard.conf   (Linux, when fcitx5/Omarchy)
~/.local/bin/agentic-dev
~/.local/share/agentic-dev/lib/  (for CLI)
```

Shell rc gets a fenced marker block in `~/.bashrc` and/or `~/.zshrc`.

## Plugin install from GitHub

After the repo is published:

```bash
herdr plugin install simoncrypta/agentic-dev-setup/plugins/dev-layout
```

The curl installer uses local copy + `herdr plugin link` instead.

## Migrating from agentic-tmux-setup

```bash
agentic-tmux uninstall
curl -fsSL https://setup.simoncrypta.dev/install.sh | bash
```

## Cloudflare hosting

Static site on Cloudflare Pages (`setup.simoncrypta.dev`). Deploy manually from this repo.

1. Create the Pages project in Cloudflare (or use an existing one named `agentic-dev-setup`)
2. Authenticate once: `npx wrangler login`
3. Deploy:

```bash
npm install
npm run deploy
```

Custom domain: set `setup.simoncrypta.dev` on the Pages project in the Cloudflare dashboard.

## Development

```bash
shellcheck install.sh lib/*.sh bin/agentic-dev config/shell/agentic-dev.inc.sh plugins/dev-layout/dev-layout.sh
./install.sh --help
agentic-dev dry-run
npm run deploy   # publish to Cloudflare Pages
```

## License

MIT — see [LICENSE](LICENSE).
