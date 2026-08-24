# agentic-dev-setup

A ready-made [Herdr](https://herdr.dev) workspace for agentic coding: sticky agent on the left, review/shell in the center, files and git on the right — one layout per worktree, with Worktrunk hooks and a `handoff` skill so agents can spawn sibling worktrees for you.

Works on **Omarchy**, **Ubuntu/Debian**, and **macOS**.

<img width="2138" height="1386" alt="image" src="https://github.com/user-attachments/assets/52d372ae-a51f-4260-b95f-d9daa3b335c1" />


## Quick install

Full stack (recommended):

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

Already running Herdr and only want the layout plugin? Jump to [Plugin only](#plugin-only).

## What you get

- **Sticky-agent layout**: agent (~⅓) + review/shell center + files/git sidebar — agent stays put while you switch tabs
- **In-repo layout plugin**: `agentic-dev.layout` (files/git sidebar is our fork of [alexarthurs/herdr-sidebar](https://github.com/alexarthurs/herdr-sidebar))
- **Review**: [hunk](https://github.com/modem-dev/hunk) (`hunk diff --watch`)
- **Editor opens**: [fresh](https://github.com/sinelaw/fresh) from the sidebar tree
- **Worktrunk plugin**: in-Herdr git worktree pickers (`prefix+shift+g/c/r`)
- **Shell commands**: `dev`, `wtc`, `wts`, `wtd`, `d`, `t`
- **worktrunk hooks**: auto-create/close Herdr workspaces on worktree start/remove
- **`handoff` skill**: agents spawn a sibling worktree subspace, apply the layout, and start your agent with the task ([Agent Skills](https://agentskills.io/home))
- **Config**: `~/.config/agentic-dev/config.toml` (agent command; review/editor fixed to hunk + fresh)
- **Omarchy/Linux**: fcitx5 hint hotkeys cleared; optional Hyprland binding patch
- **Ubuntu/Debian**: apt + GitHub/mise installs when needed

### Layout

One Herdr workspace per worktree. Switching tabs moves the agent pane with you — it is not its own tab.

```
┌──────────────────────────────────────────────────────────────────┐
│  workspace tabs   review   shell   editor           PREFIX  #h │
├─────────────────────────┬────────────────────────────────────────┤
│                         │                                        │
│   agent                 │   active tool tab                      │
│   (cursor / grok / pi / │                                        │
│    codex / opencode /   │   review    → hunk diff --watch        │
│    claude)              │                                        │
│                         │   editor    → fresh                    │
│   sticky left pane      │                                        │
│                         │   shell     → terminal                 │
│                         │                                        │
│   prefix+1              │   prefix+2/3/4  or  Alt/Option+1/2/3   │
└─────────────────────────┴────────────────────────────────────────┘
```

Prefix is `Ctrl-Space` (same as [Omarchy tmux](https://learn.omacom.io/2/the-omarchy-manual/53/hotkeys#tmux)). `prefix+d` applies this layout in the current workspace.

### First-run prompt

On install you'll pick the **agent** command. Review is always [hunk](https://github.com/modem-dev/hunk); file opens are always [fresh](https://github.com/sinelaw/fresh).

**Agent**

1. `cursor` (runs `cursor-agent`)
2. `grok`
3. `pi`
4. `codex`
5. `opencode`
6. `claude`
7. custom

Saved to `~/.config/agentic-dev/config.toml`. Change the agent later with `agentic-dev reconfigure`.

### Handoff skill

The full installer deploys [`skills/handoff/`](skills/handoff/) to `~/.agents/skills/handoff`. Call it by name: **`handoff`**.

From the main repo checkout inside Herdr, it opens a sibling worktree as a Herdr worktree-group child (subspace), applies the sticky-agent layout, starts your configured agent, and remembers where that work lives — so you can parallelize features without leaving the terminal.

Agents that already discover `~/.agents/skills` (Cursor) need no extra link. Grok, Codex, OpenCode, Claude, and pi get a symlink into their agent-specific skills dir. Manual install:

```bash
npx skills add simoncrypta/agentic-dev-setup --skill handoff -g
```

## Plugin only

Use this when you already have Herdr set up and only want the **layout plugin** (`agentic-dev.layout`).

```bash
herdr plugin install simoncrypta/agentic-dev-setup/plugins/agentic-layout --ref v0.3.2
```

| Comes with plugin install | Full install also adds |
|---------------------------|------------------------|
| Sticky agent + review/shell + files/git sidebar | Shell commands (`dev`, `wtc`, `wts`, `wtd`, `d`, `t`) |
| Layout actions (`create`, `apply`, tab focus, …) | `agentic-dev` CLI (`doctor`, `update`, `reconfigure`, `uninstall`) |
| Sidebar fork of [herdr-sidebar](https://github.com/alexarthurs/herdr-sidebar) (built on install) | `handoff` skill |
| | Worktrunk hooks + herdr-worktrunk plugin |
| | Herdr keybindings / config templates |
| | Dependency install (Herdr, worktrunk, [hunk](https://github.com/modem-dev/hunk), [fresh](https://github.com/sinelaw/fresh), agents) |
| | Omarchy / Hyprland / fcitx5 desktop fixes |

**Requires:** [Herdr](https://herdr.dev) 0.8+, `jq`, a Rust toolchain (sidebar build), [hunk](https://github.com/modem-dev/hunk), and [fresh](https://github.com/sinelaw/fresh). You wire keybindings yourself (see below).

### Trust and security

Herdr plugins are ordinary code that runs as your user. See [Herdr: Trust and security](https://herdr.dev/docs/plugins/#trust-and-security). Skim [`plugins/agentic-layout/herdr-plugin.toml`](plugins/agentic-layout/herdr-plugin.toml) and [`plugins/agentic-layout/layout.sh`](plugins/agentic-layout/layout.sh) first; prefer interactive install (no `--yes`) the first time.

**Unpinned / local:**

```bash
herdr plugin install simoncrypta/agentic-dev-setup/plugins/agentic-layout

git clone https://github.com/simoncrypta/agentic-dev-setup.git
cd agentic-dev-setup/plugins/agentic-layout && cargo build --release -p herdr-sidebar
herdr plugin link ~/path/to/agentic-dev-setup/plugins/agentic-layout
```

**Verify:**

```bash
herdr plugin list
herdr plugin action invoke agentic-dev.layout.create
```

### Wire up keybindings

Add plugin actions to `~/.config/herdr/config.toml`. Also set `close_tab = ""` and `close_pane = ""`. Minimum bindings:

```toml
[[keys.command]]
key = "prefix+d"
type = "plugin_action"
command = "agentic-dev.layout.apply"

[[keys.command]]
key = "prefix+1"
type = "plugin_action"
command = "agentic-dev.layout.focus-agent"

[[keys.command]]
key = "prefix+2"
type = "plugin_action"
command = "agentic-dev.layout.select-review"

[[keys.command]]
key = "prefix+3"
type = "plugin_action"
command = "agentic-dev.layout.select-shell"

[[keys.command]]
key = "prefix+k"
type = "plugin_action"
command = "agentic-dev.layout.close-tab"

[[keys.command]]
key = "prefix+x"
type = "plugin_action"
command = "agentic-dev.layout.close-pane"
```

Or copy the full example from [`config/herdr/config.toml`](config/herdr/config.toml) (Linux / Alt) or [`config/herdr/config.macos.toml`](config/herdr/config.macos.toml) (macOS / Option), then `herdr server reload-config`.

Optional agent config (`~/.config/agentic-dev/config.toml`):

```toml
[agent]
command = "cursor-agent"

[layout]
review = "hunk"
editor = "fresh"
```

Without config: agent defaults to `cursor-agent`, review to `hunk diff --watch`, file opens to `fresh`.

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
| Layout plugin | Sticky agent layout | apply layout, review/shell/sidebar |
| herdr-worktrunk plugin | Git worktree pickers | open / open-current / remove |

`prefix+shift+d` is **not** bound to worktrunk remove — that key is Herdr’s native close-workspace by default, so remove lives on `prefix+shift+r` instead. Workspace close is on `prefix+shift+k` (Omarchy’s kill-session analog).

### Dev layout

| Key | Action |
|-----|--------|
| `prefix+d` | Apply / ensure sticky-agent layout |
| `prefix+1` | Focus agent pane (recreates if crashed) |
| `prefix+2` | Review tab (`hunk diff --watch`) |
| `prefix+3` | Shell tab |
| `prefix+4` | Files pane |
| `Alt+1` / `Alt+2` / `Alt+3` (Option on macOS) | Same tabs in a **dev** workspace; otherwise focus tab 1/2/3 |

Prefix `1–4` no-op outside a valid dev-layout workspace. Only `prefix+d` / `create` / `apply` create one.

### Tabs (≈ Omarchy windows)

| Key | Action |
|-----|--------|
| `prefix+c` | New tab |
| `prefix+k` | Close file tab |
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
| `prefix+x` | Close pane (file tabs: same as prefix+k) |
| `prefix+z` | Zoom pane |
| `Ctrl+Alt+Left/Right/Up/Down` (Ctrl+Option on macOS) | Focus left / right / up / down |

### Git worktrees (herdr-worktrunk)

| Key | Action |
|-----|--------|
| `prefix+shift+g` | Open / create worktree from default branch |
| `prefix+shift+c` | Open / create worktree from current branch |
| `prefix+shift+r` | Remove worktree |

Shell equivalents outside Herdr: `wtc`, `wts`, `wtd`.

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
agentic-dev reconfigure  # change agent command (not a full redeploy)
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
- Treats native `SUPER+CTRL+RETURN` → Herdr as first-class
- Optionally remaps `SUPER+ALT+RETURN` from Tmux to Herdr
- Syncs `~/.config/omarchy/defaults/agent` when you pick `grok` / `pi` / `claude` / `codex` / `opencode`

### Ubuntu / Debian

Dependencies install via **mise** when available, then **apt**:

```bash
sudo apt-get install -y git fzf jq lazygit curl
```

Tools not in apt are fetched automatically:

- **herdr** — mise, then [herdr.dev/install.sh](https://herdr.dev/install.sh)
- **worktrunk** (`wt`) — mise, then GitHub release binary to `~/.local/bin`
- **hunk** — mise, brew, or [hunk.dev/install.sh](https://hunk.dev/install.sh) ([modem-dev/hunk](https://github.com/modem-dev/hunk))
- **fresh** — brew `fresh-editor` or the [Fresh installer](https://getfresh.dev/) ([sinelaw/fresh](https://github.com/sinelaw/fresh))
- **grok** — `mise use -g npm:@xai-official/grok` when selected as the agent
- **pi** — `mise use -g pi` when selected as the agent

On Ubuntu with **Hyprland**, the installer can optionally add `SUPER+ALT+RETURN` → `herdr`. If you use **fcitx5**, the `Ctrl+Alt+H/J` hint hotkey fix applies the same way as on Omarchy.

### fcitx5 `Ctrl+Alt+H` conflict

Omarchy runs fcitx5 for emoji and compose. By default fcitx5 binds `Ctrl+Alt+H/J` to spell-hint toggles. This installer clears those hotkeys in `~/.config/fcitx5/conf/keyboard.conf` so the chords stay free.

See [Omarchy discussion #1578](https://github.com/basecamp/omarchy/discussions/1578).

### Hyprland launcher

On Omarchy or any Hyprland system, the installer can patch `SUPER+ALT+RETURN` to launch Herdr. Omarchy Quattro uses `{ omarchy = "terminal-herdr" }` in `bindings.lua`; other setups get a generic `xdg-terminal-exec herdr` binding.

## Dependencies

Installed only if missing (mise first, then Omarchy `pkg add`, Homebrew, apt, pacman, or upstream installers):

- [herdr](https://herdr.dev) (`mise use -g herdr`, brew, or `curl -fsSL https://herdr.dev/install.sh | sh`)
- Official [Herdr agent integration](https://herdr.dev/docs/integrations/) for the selected agent
- git, worktrunk (`wt`), fzf, jq, lazygit
- [hunk](https://github.com/modem-dev/hunk) (`hunk diff --watch` in the review tab)
- [fresh](https://github.com/sinelaw/fresh) (sidebar file opens)
- [grok](https://github.com/xai-org) (`mise use -g npm:@xai-official/grok`) when selected as the agent
- pi (`mise use -g pi`) when selected as the agent

## Files installed

```
~/.config/agentic-dev/config.toml
~/.config/agentic-dev/shell/agentic-dev.{sh,zsh,inc.sh}
~/.config/herdr/config.toml
~/.config/herdr/plugins/               layout plugin (managed GitHub install)
~/.config/worktrunk/herdr-layout.sh
~/.config/worktrunk/config.toml   (created if missing; update rewrites Repo_Branch session labels to Branch_Repo)
~/.config/fcitx5/conf/keyboard.conf   (Linux, when fcitx5/Omarchy)
~/.config/nvim/lua/plugins/agentic-dev-explorer.lua   (LazyVim only; tree on the right)
~/.config/fresh/config.json   (file_explorer.side = right, if unset)
~/.local/bin/agentic-dev
~/.local/share/agentic-dev/lib/  (for CLI)
~/.agents/skills/handoff/        handoff skill
```

Shell rc gets a fenced marker block in `~/.bashrc` and/or `~/.zshrc`.

## Development

```bash
shellcheck install.sh lib/*.sh bin/agentic-dev config/shell/agentic-dev.inc.sh plugins/agentic-layout/layout.sh
./install.sh --help
agentic-dev dry-run
npm run deploy   # publish to Cloudflare Pages
```

## License

MIT — see [LICENSE](LICENSE).
