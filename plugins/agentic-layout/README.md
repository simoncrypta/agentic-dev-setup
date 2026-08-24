# Agentic Layout

Herdr plugin for the agentic-dev three-column workspace:

```text
Herdr dock | agent (2/6) | review or shell (3/6) | files/git sidebar (1/6)
```

Install the full stack (Herdr, Worktrunk, agents, keybindings) via [agentic-dev-setup](https://github.com/simoncrypta/agentic-dev-setup).

## Plugin only

```bash
herdr plugin install simoncrypta/agentic-dev-setup/plugins/agentic-layout --ref v0.3.5 --yes
```

Local development:

```bash
cargo build --release -p herdr-sidebar
herdr plugin link ~/path/to/agentic-dev-setup/plugins/agentic-layout
```

## Actions

| Action | Description |
|--------|-------------|
| `create` | Create layout; honors `WT_HERDR_*` handoff env |
| `apply` | Idempotently repair plugin-owned panes |
| `focus-agent` | Focus the persistent agent pane |
| `select-review` | Show review pane (no respawn) |
| `refresh-review` | Focus review and restart `hunk diff --watch` |
| `select-shell` | Show live shell pane (no respawn) |
| `toggle-sidebar` | Toggle files pane zoom |
| `select-files` | Files view |
| `select-source-control` | Source control view |
| `open-editor` | Open a path in a new tab (`layout.sh open-editor <path>`) |
| `close-tab` | Close the current file tab and land on the previous one |
| `close-pane` | Close an extra split; an editor center closes the tab instead |

Sidebar keys in embedded mode: `v` refreshes the center review view.

## Config

Reads `~/.config/agentic-dev/config.toml` when present:

```toml
[layout]
review = "hunk diff"
editor = "fresh"
agent_ratio = 0.333333
sidebar_ratio = 0.166667
```

## Sidebar fork

Files/git sidebar is our fork of [alexarthurs/herdr-sidebar](https://github.com/alexarthurs/herdr-sidebar) (MIT). See `THIRD_PARTY_NOTICES.md`.

## License

MIT
