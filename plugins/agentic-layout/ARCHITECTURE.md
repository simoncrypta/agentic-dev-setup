# Architecture

The plugin is three Bash modules:

- `state.sh` — reentrant layout lock, probe, load, save, v3→v4 migrate (drops `main_tab_id`). Every state write goes through the lock.
- `topology.sh` — Shell tab always, Review on demand, four panes, dock-then-focus tab switch
- `layout.sh` — config, Herdr helpers, actions, events

## Pane topology

Shell is the only layout tab at create/apply. Review is created on demand (`select-review` / `prefix+2`) and closed after the round (`close-review` / `prefix+k` / hunk quit). Agent and sidebar follow the active center:

```text
Shell tab (tab 1):    [ agent | shell                    | sidebar ]
Review tab (on demand): [ agent | review (hunk diff --watch) | sidebar ]
Editor tab (file):    [ agent | editor (fresh <path>)      | sidebar ]
```

Herdr's default `main` tab is adopted as Shell (tab 1), including the recovery case where that tab is still labeled `Review`. A leftover Review tab from an older layout is adopted, not recreated. Default focus is shell. Missing Review is healthy — startup does not respawn hunk.

`_activate_tab` is the only switch path. Plugin keys (Alt+Left/Right, Alt+1..9, prefix+2/+3) dock agent+sidebar onto the **hidden** target tab, persist the new pane ids under the layout lock, then focus — so `tab.focused` never races stale ids, and the destination is never painted as a full-width center. `tab.focused` is the backup for native/mouse switches and docks without re-focusing. Agent is moved first at its final 2/6 width, then swapped left, so the PTY is not resized (same trick the sidebar uses: one in-process move, no respawn). `pane split` and `pane move --ratio` are both left-keep. Agent move uses 2/6 then swap into that left slot; sidebar move uses 3/4 of the remaining 4/6 so the center is 3/6 and the sidebar is 1/6.

Editor tabs are separate Herdr tabs (`open-editor`) but use the same dock: opening or focusing a file keeps agent + sidebar beside the editor.

`close-tab` (prefix+k) docks stickies onto the previous tab, then closes the file tab. On Review it docks back to Shell and clears review state. `close-pane` (prefix+x) does the same for an editor center and ignores layout columns. Shell is not closable this way. Quit (`q`) in hunk fires `pane.exited` and closes the Review tab.

## State

Version 4 JSON per workspace: `shell_tab_id`, `review_tab_id`, pane ids, `active_center_view`, editor registry. There is no `main_tab_id`.

## Integration

`agentic-dev-setup` installs this plugin as `agentic-dev.layout` from `plugins/agentic-layout`.
