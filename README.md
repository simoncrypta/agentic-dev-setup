# agentic-dev-setup

Shareable Herdr + worktrunk dev layout for agentic coding workflows. Works on **Omarchy**, **Ubuntu/Debian**, and **macOS**.

Successor to [agentic-tmux-setup](https://github.com/simoncrypta/agentic-tmux-setup) — same sticky-agent layout, powered by [Herdr](https://herdr.dev) instead of tmux.

<img width="3396" height="1390" alt="image" src="https://github.com/user-attachments/assets/eb89337e-262d-4929-bdb8-def28c4a3baf" />


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

## Plugin only

Use this if you already have Herdr configured and only want the **dev layout plugin** (`agentic-dev.dev-layout`) — sticky agent pane + review / explorer / terminal tabs.

**Requires:** [Herdr](https://herdr.dev) 0.7+, `jq`, and the review-tab tools you use (`tuicr`, `nvim`, etc.).

### Trust and security

Herdr plugins are ordinary code that runs as your user and can call the full Herdr CLI. See [Herdr: Trust and security](https://herdr.dev/docs/plugins/#trust-and-security).

Before installing:

1. Skim [`plugins/dev-layout/herdr-plugin.toml`](plugins/dev-layout/herdr-plugin.toml) and [`plugins/dev-layout/dev-layout.sh`](plugins/dev-layout/dev-layout.sh).
2. Prefer interactive install (no `--yes`) the first time — Herdr shows a preview of the source and commands.
3. Pin a release when you want a fixed revision:

```bash
herdr plugin install simoncrypta/agentic-dev-setup/plugins/dev-layout --ref v0.1.1
```

Use `--yes` only for sources you already trust. The full `curl | bash` installer copies and links the plugin locally — equivalent to trusting this repository.

### Install the plugin

**From GitHub** (review the preview, then confirm):

```bash
herdr plugin install simoncrypta/agentic-dev-setup/plugins/dev-layout
```

**Pinned to a release:**

```bash
herdr plugin install simoncrypta/agentic-dev-setup/plugins/dev-layout --ref v0.1.1
```

**From a local clone** (development):

```bash
git clone https://github.com/simoncrypta/agentic-dev-setup.git
herdr plugin link ~/path/to/agentic-dev-setup/plugins/dev-layout
```

**Verify:**

```bash
herdr plugin list
herdr plugin action invoke agentic-dev.dev-layout.create
```

### Wire up keybindings

Add the plugin actions to `~/.config/herdr/config.toml`. Minimum bindings:

```toml
[[keys.command]]
key = "prefix+d"
type = "plugin_action"
command = "agentic-dev.dev-layout.apply"

[[keys.command]]
key = "prefix+1"
type = "plugin_action"
command = "agentic-dev.dev-layout.focus_agent"

[[keys.command]]
key = "alt+1"
type = "plugin_action"
command = "agentic-dev.dev-layout.select_review"

[[keys.command]]
key = "alt+2"
type = "plugin_action"
command = "agentic-dev.dev-layout.select_explorer"

[[keys.command]]
key = "alt+3"
type = "plugin_action"
command = "agentic-dev.dev-layout.select_terminal"
```

Or copy the full example from [`config/herdr/config.toml`](config/herdr/config.toml) in this repo (prefix `Ctrl-Space`, pane focus on `Ctrl+Alt+HJKL`, etc.).

Reload after editing:

```bash
herdr server reload-config
```

### Agent command (optional)

The plugin reads settings from the Herdr plugin config directory first, then falls back to the full-setup path:

1. `$(herdr plugin config-dir agentic-dev.dev-layout)/config.toml` — preferred ([Herdr convention](https://herdr.dev/docs/plugins/#commands-and-environment))
2. `~/.config/agentic-dev/config.toml` — when using the full installer

```bash
herdr plugin config-dir agentic-dev.dev-layout
cp plugins/dev-layout/config.toml.example "$(herdr plugin config-dir agentic-dev.dev-layout)/config.toml"
# edit command / editor, then re-run create or apply
```

Minimal config:

```toml
[agent]
command = "agent"

[layout]
editor = "nvim"
```

Without config, the agent pane defaults to `agent` and the explorer tab uses `$EDITOR` or `nvim`.

### Invoke without keybindings

```bash
herdr plugin action invoke agentic-dev.dev-layout.create   # create layout in focused workspace
herdr plugin action invoke agentic-dev.dev-layout.apply    # ensure layout exists
herdr plugin action invoke agentic-dev.dev-layout.select_review
```

The full installer also adds shell commands (`dev`, `wtc`, …), worktrunk hooks, and Linux desktop fixes — use [Quick install](#quick-install) if you want those.

## Migrating from agentic-tmux-setup

```bash
agentic-tmux uninstall
curl -fsSL https://setup.simoncrypta.dev/install.sh | bash
```

## Cloudflare hosting

Install CDN on Cloudflare Pages (`agentic-dev-setup.pages.dev`) with custom domain `setup.simoncrypta.dev`.

| URL | Behavior |
|-----|----------|
| `https://setup.simoncrypta.dev/` | 301 → GitHub repo (Worker) |
| `https://setup.simoncrypta.dev/install.sh` | Installer script (Worker → Pages) |
| `https://agentic-dev-setup.pages.dev/` | 301 → GitHub repo (`public/_redirects`) |

The custom domain uses a tiny Worker ([`workers/setup-domain/`](workers/setup-domain/)) with `custom_domain = true`, which creates the Cloudflare DNS record automatically. It redirects `/` to GitHub and proxies everything else to the Pages deployment.

Deploy:

```bash
npm install
npm run deploy   # Pages assets + setup.simoncrypta.dev Worker
```

DNS troubleshooting: if a hostname was queried before the record existed, flush local cache (`resolvectl flush-caches`) and retry. `ping setup.simoncrypta.dev` should resolve to a Cloudflare anycast IP (e.g. `172.64.80.1`).

Manual DNS fallback (Pages-only, requires `CLOUDFLARE_API_TOKEN` with Zone.DNS Edit):

```bash
CLOUDFLARE_API_TOKEN=... bash scripts/ensure-setup-dns.sh
```

## Development

```bash
shellcheck install.sh lib/*.sh bin/agentic-dev config/shell/agentic-dev.inc.sh plugins/dev-layout/dev-layout.sh
./install.sh --help
agentic-dev dry-run
npm run deploy   # publish to Cloudflare Pages
```

## License

MIT — see [LICENSE](LICENSE).
