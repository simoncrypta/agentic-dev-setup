# agentic-dev-setup

Shareable Herdr + worktrunk dev layout for agentic coding workflows. Works on **Omarchy**, **Ubuntu/Debian**, and **macOS**.

Successor to [agentic-tmux-setup](https://github.com/simoncrypta/agentic-tmux-setup) — same sticky-agent layout, powered by [Herdr](https://herdr.dev) instead of tmux.

<img width="3396" height="1390" alt="image" src="https://github.com/user-attachments/assets/eb89337e-262d-4929-bdb8-def28c4a3baf" />


## Quick install

```bash
curl -fsSL https://setup.simoncrypta.dev/install.sh | bash
```

Non-interactive (skip layout prompts):

```bash
curl -fsSL https://setup.simoncrypta.dev/install.sh | bash -s -- --yes
```

From a local clone:

```bash
cd /path/to/agentic-dev-setup
./install.sh
```

## What you get

- **Herdr layout**: sticky agent pane (left) + tabs for review (`tuicr` or `hunk`), explorer (`nvim` / `nano` / `tode` / `fresh`), terminal
- **Dev layout plugin**: `agentic-dev.dev-layout` (pinned from `simoncrypta/herdr-dev-layout`)
- **Worktrunk plugin**: in-Herdr git worktree pickers (`prefix+shift+g/c/r`)
- **Shell commands**: `dev`, `wtc`, `wts`, `wtd`, `d`, `t`
- **worktrunk hooks**: auto-create/close Herdr workspaces on worktree start/remove
- **Config**: `~/.config/agentic-dev/config.toml` (agent, review, and explorer commands)
- **Agent skill**: `handoff` at `~/.agents/skills/handoff` ([Agent Skills](https://agentskills.io/home)); extra symlink only for agents that do not read that path
- **Omarchy/Linux**: fcitx5 hint hotkeys cleared (`Ctrl+Alt+H/J`); optional Hyprland binding patch
- **Ubuntu/Debian**: apt installs for common deps; herdr/worktrunk and selected review/explorer tools via GitHub when needed

### Layout

One Herdr workspace per worktree. The agent pane stays on the left (~50%); tool tabs are on the right. Switching tabs moves the agent pane with you — it is not its own tab.

```
┌──────────────────────────────────────────────────────────────────┐
│  workspace tabs   review   explorer   terminal      PREFIX  #h │
├─────────────────────────┬────────────────────────────────────────┤
│                         │                                        │
│   agent                 │   active tool tab                      │
│   (cursor / grok / pi / │                                        │
│    codex / opencode /   │   review    → tuicr or hunk            │
│    claude)              │                                        │
│                         │   explorer  → nvim / nano / tode /     │
│   sticky left pane      │                 fresh                  │
│                         │   terminal  → shell                    │
│                         │                                        │
│   prefix+1              │   prefix+2/3/4  or  Alt/Option+1/2/3   │
└─────────────────────────┴────────────────────────────────────────┘
```

Prefix is `Ctrl-Space` (same as [Omarchy tmux](https://learn.omacom.io/2/the-omarchy-manual/53/hotkeys#tmux)). `prefix+d` applies this layout in the current workspace.

### First-run prompt

On install you'll pick the command for each pane:

**Agent**

1. `cursor` (runs `cursor-agent`)
2. `grok`
3. `pi`
4. `codex`
5. `opencode`
6. `claude`
7. custom

**Review**

1. `tuicr`
2. `hunk` ([hunk.dev](https://hunk.dev) — launches `hunk diff`)
3. custom

**Explorer**

1. `nvim`
2. `nano`
3. `tode` ([terminal-code.com](https://terminal-code.com/))
4. `fresh` ([getfresh.dev](https://getfresh.dev/))
5. custom

Saved to `~/.config/agentic-dev/config.toml`. Change later with `agentic-dev reconfigure`.

### Agent skill (`handoff`)

Install deploys [`skills/handoff/`](skills/handoff/) to the Agent Skills path [`~/.agents/skills/handoff`](https://agentskills.io/home). Call it by name: **`handoff`**.

Primary workflow: from the main repo checkout inside Herdr, spawn a sibling worktree as a Herdr worktree-group child (subspace), apply the sticky-agent layout, start the configured agent (`cursor-agent` for Cursor, `grok`, …), and remember where it is.

Agents that already discover `~/.agents/skills` (Cursor) need no extra link. Grok, Codex, OpenCode, Claude, and pi get a symlink into their agent-specific global skills dir:

| Agent choice | Extra link |
|--------------|------------|
| `cursor` (`cursor-agent`) | none (`~/.agents/skills` only) |
| `grok` | `~/.grok/skills/handoff` |
| `pi` | `~/.pi/agent/skills/handoff` |
| `codex` | `~/.codex/skills/handoff` |
| `opencode` | `~/.config/opencode/skills/handoff` |
| `claude` | `~/.claude/skills/handoff` |
| custom | none |

Manual install:

```bash
npx skills add simoncrypta/agentic-dev-setup --skill handoff -g
```

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

Prefix is **`Ctrl-Space`**, matching [Omarchy tmux](https://learn.omacom.io/2/the-omarchy-manual/53/hotkeys#tmux). Bindings live in [`config/herdr/config.toml`](config/herdr/config.toml) (Linux / Alt) and [`config/herdr/config.macos.toml`](config/herdr/config.macos.toml) (macOS / Option).

### Roles

| Layer | Owns | Examples |
|-------|------|----------|
| Native Herdr | Panes, tabs, workspaces | splits, close workspace, detach |
| Dev-layout plugin | Sticky agent layout | apply layout, review/explorer/terminal |
| herdr-worktrunk plugin | Git worktree pickers | open / open-current / remove |

`prefix+shift+d` is **not** bound to worktrunk remove — that key is Herdr’s native close-workspace by default, so remove lives on `prefix+shift+r` instead. Workspace close is on `prefix+shift+k` (Omarchy’s kill-session analog).

### Dev layout

| Key | Action |
|-----|--------|
| `prefix+d` | Apply / ensure sticky-agent layout |
| `prefix+1` | Focus agent pane (recreates if crashed) |
| `prefix+2` | Review tab (configured `tuicr` or `hunk`) |
| `prefix+3` | Explorer tab (configured `nvim` / `nano` / `tode` / `fresh`) |
| `prefix+4` | Terminal tab |
| `Alt+1` / `Alt+2` / `Alt+3` (Option on macOS) | Same tabs in a **dev** workspace; otherwise focus tab 1/2/3 |

Prefix `1–4` no-op outside a valid dev-layout workspace (they never create a layout). Only `prefix+d` / `create` / `apply` create one.

### Tabs (≈ Omarchy windows)

| Key | Action |
|-----|--------|
| `prefix+c` | New tab |
| `prefix+k` | Close tab |
| `prefix+shift+t` | Rename tab |
| `prefix+n` / `Alt+Right` (Option on macOS) | Next tab |
| `prefix+p` / `Alt+Left` (Option on macOS) | Previous tab |

### Workspaces (≈ Omarchy sessions)

| Key | Action |
|-----|--------|
| `Alt+Up` / `Alt+Down` (Option on macOS) | Previous / next workspace |
| `prefix+w` | Workspace picker |
| `prefix+shift+n` | New workspace |
| `prefix+shift+w` | Rename workspace |
| `prefix+shift+k` | Close workspace |
| `prefix+shift+q` | Detach |

### Panes

| Key | Action |
|-----|--------|
| `prefix+h` | Split below |
| `prefix+v` | Split beside |
| `prefix+x` | Close pane |
| `prefix+z` | Zoom pane |
| `Ctrl+Alt+H/J/K/L` (Ctrl+Option on macOS) | Focus left / down / up / right |

Pane focus uses vim keys instead of Omarchy’s `Ctrl+Alt+Arrows` so it stays clear of desktop/arrow chords; on Omarchy/Linux the installer also clears fcitx5’s `Ctrl+Alt+H/J` hint hotkeys.

### Git worktrees (herdr-worktrunk)

| Key | Action |
|-----|--------|
| `prefix+shift+g` | Open / create worktree from default branch |
| `prefix+shift+c` | Open / create worktree from current branch |
| `prefix+shift+r` | Remove worktree |

Shell equivalents still work outside Herdr: `wtc`, `wts`, `wtd`.

### General

| Key | Action |
|-----|--------|
| `prefix+q` | Reload Herdr config |

Tab switching works even when the agent pane is missing — the agent is recreated lazily on the next tab switch or `prefix+1`.

## Post-install CLI

```bash
agentic-dev help         # full reference
agentic-dev doctor       # check deps + integration
agentic-dev update       # re-sync configs, helper, and skill
agentic-dev reconfigure  # change agent / review / explorer commands (not a full redeploy)
agentic-dev dry-run      # preview changes
agentic-dev uninstall    # remove integration
```

## Omarchy / Linux notes

### Omarchy Quattro

Hyprland user config is Lua (`~/.config/hypr/bindings.lua`), not `bindings.conf`. The installer:

- Detects Omarchy via the `omarchy` CLI / `$OMARCHY_PATH` / `~/.local/share/omarchy`
- Installs tools with **mise** first (`mise use -g`), matching `omarchy default agent`
- Installs Arch packages with `omarchy pkg add` (not raw `pacman`)
- Restarts fcitx5 with `omarchy restart xcompose`
- Patches `bindings.lua` using Omarchy's helper: `{ omarchy = "terminal-herdr" }`
- Treats native `SUPER+CTRL+RETURN` → Herdr as first-class (no extra binding required)
- Optionally remaps `SUPER+ALT+RETURN` from Tmux to Herdr
- Syncs `~/.config/omarchy/defaults/agent` when you pick `grok` / `pi` / `claude` / `codex` / `opencode`

### Ubuntu / Debian

Dependencies install via **mise** when available, then **apt**:

```bash
sudo apt-get install -y git fzf jq neovim lazygit curl
```

Tools not in apt are fetched automatically:

- **herdr** — mise, then [herdr.dev/install.sh](https://herdr.dev/install.sh)
- **worktrunk** (`wt`) — mise, then GitHub release binary to `~/.local/bin`
- **tuicr** — GitHub release binary to `~/.local/bin` when selected as review
- **hunk** — mise, brew, or [hunk.dev/install.sh](https://hunk.dev/install.sh) when selected as review
- **tode** — [tode.sh/install](https://tode.sh/install) when selected as explorer
- **fresh** — brew `fresh-editor` or the [Fresh installer](https://getfresh.dev/) when selected as explorer
- **grok** — `mise use -g npm:@xai-official/grok` when selected as the agent
- **pi** — `mise use -g pi` when selected as the agent

Homebrew (Linuxbrew) is used when present if mise cannot install the tool.

On Ubuntu with **Hyprland**, the installer can optionally add `SUPER+ALT+RETURN` → `herdr` in `~/.config/hypr/bindings.lua` (or leftover `bindings.conf`). If you use **fcitx5** (common on CJK setups), the `Ctrl+Alt+H/J` hint hotkey fix applies the same way as on Omarchy.

### fcitx5 `Ctrl+Alt+H` conflict

Omarchy runs fcitx5 for emoji and compose. By default fcitx5 binds `Ctrl+Alt+H/J` to spell-hint toggles, which conflicts with Herdr pane focus. This installer clears those hotkeys in `~/.config/fcitx5/conf/keyboard.conf`.

See [Omarchy discussion #1578](https://github.com/basecamp/omarchy/discussions/1578).

### Hyprland launcher

On Omarchy or any Hyprland system, the installer can patch `SUPER+ALT+RETURN` to launch Herdr (replacing Tmux if present). You'll be prompted during install.

Omarchy Quattro uses `{ omarchy = "terminal-herdr" }` in `bindings.lua`. Other Hyprland setups get a generic `xdg-terminal-exec herdr` binding.

## Dependencies

Installed only if missing (mise first, then Omarchy `pkg add`, Homebrew, apt, pacman, or upstream installers):

- [herdr](https://herdr.dev) (`mise use -g herdr`, brew, or `curl -fsSL https://herdr.dev/install.sh | sh`)
- Official [Herdr agent integration](https://herdr.dev/docs/integrations/) for the selected agent (`herdr integration install cursor|grok|pi|…`)
- git, worktrunk (`wt`), fzf, jq, lazygit
- selected review tool: [tuicr](https://github.com/agavra/tuicr) or [hunk](https://github.com/modem-dev/hunk)
- selected explorer: neovim, nano, [tode](https://terminal-code.com/), or [fresh](https://getfresh.dev/)
- [grok](https://github.com/xai-org) (`mise use -g npm:@xai-official/grok`) when selected as the agent
- pi (`mise use -g pi`) when selected as the agent

## Files installed

```
~/.config/agentic-dev/config.toml
~/.config/agentic-dev/shell/agentic-dev.{sh,zsh,inc.sh}
~/.config/herdr/config.toml
~/.config/herdr/plugins/dev-layout/
~/.config/worktrunk/herdr-layout.sh
~/.config/worktrunk/config.toml   (created if missing; update rewrites Repo_Branch session labels to Branch_Repo)
~/.config/fcitx5/conf/keyboard.conf   (Linux, when fcitx5/Omarchy)
~/.local/bin/agentic-dev
~/.local/share/agentic-dev/lib/  (for CLI)
```

Shell rc gets a fenced marker block in `~/.bashrc` and/or `~/.zshrc`.

## Plugin only

Use this if you already have Herdr configured and only want the **dev layout plugin** (`agentic-dev.dev-layout`) — sticky agent pane + review / explorer / terminal tabs.

**Requires:** [Herdr](https://herdr.dev) 0.7+, `jq`, and the tools you use in each tab (`tuicr` or `hunk`, `nvim` / `nano` / `tode` / `fresh`, etc.).

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

Or copy the full example from [`config/herdr/config.toml`](config/herdr/config.toml) (Linux / Alt) or [`config/herdr/config.macos.toml`](config/herdr/config.macos.toml) (macOS / Option).

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
# edit command / review / editor, then re-run create or apply
```

Minimal config:

```toml
[agent]
command = "cursor-agent"

[layout]
review = "tuicr"
editor = "nvim"
```

Without config, the agent pane defaults to `cursor-agent`, review to `tuicr`, and the explorer tab uses `$EDITOR` or `nvim`.

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

`setup.simoncrypta.dev` is a Worker ([`workers/setup-domain/`](workers/setup-domain/)) with `custom_domain = true`. It redirects `/` to GitHub and proxies other paths to GitHub raw `master` (60s cache), so a push to `master` updates `curl | bash` without a Cloudflare rebuild.

Cloudflare Pages (`agentic-dev-setup.pages.dev`) is a Direct Upload snapshot of `public/` — it is **not** connected to Git. GitHub Actions (`.github/workflows/ci.yml`) runs tests on every push/PR, and on `master` also runs `npm run deploy` when `CLOUDFLARE_API_TOKEN` is set.

| URL | Behavior |
|-----|----------|
| `https://setup.simoncrypta.dev/` | 301 → GitHub repo (Worker) |
| `https://setup.simoncrypta.dev/install.sh` | Installer (Worker → GitHub raw `master`) |
| `https://agentic-dev-setup.pages.dev/` | 301 → GitHub repo (`public/_redirects`) |

Manual deploy:

```bash
npm install
npm run deploy   # Pages assets + setup.simoncrypta.dev Worker
```

Create a token with **Edit Cloudflare Workers** at [Account API tokens](https://dash.cloudflare.com/?to=/:account/api-tokens) and store it as the repo secret `CLOUDFLARE_API_TOKEN`. Account id defaults to this project's Cloudflare account; override with repo variable `CLOUDFLARE_ACCOUNT_ID` if needed.

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
