# Third-party notices

## herdr-sidebar

The sidebar TUI in `crates/herdr-sidebar/` is derived from
[herdr-sidebar](https://github.com/alexarthurs/herdr-sidebar) by Alex Arthurs.

Copyright (c) Alex Arthurs and contributors  
License: MIT (see `crates/herdr-sidebar/UPSTREAM_LICENSE`)

Modifications for agentic-dev-setup:

- Embedded mode (no auto-dock; layout-owned right pane)
- Default dock-right; external editor via `agentic-dev.layout.open-editor`
- Simplified source-control surface (staged/changes only in embedded mode)
- Review refresh integration with the layout center pane
