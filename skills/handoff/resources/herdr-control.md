# Herdr control (condensed)

Aligned with upstream Herdr agent skill. Installed binary wins: `herdr --help`, group help (`herdr pane`, `herdr agent`, …). Optional: `herdr --skill`.

## Guard

```bash
test "${HERDR_ENV:-}" = 1
```

## Primitives

- **Workspace / tab / pane** — topology
- **Pane commands** — shells, tests, servers, raw IO
- **Agent commands** — recognized coding agents (`idle` / `working` / `blocked` / `done` / `unknown`)

`agent start` needs an existing available shell pane; it does not create layout.

IDs: `w1`, `w1:t1`, `w1:p1`. Prefer `--current` or explicit IDs/names over another client’s UI focus.

```bash
printf '%s\n' "$HERDR_WORKSPACE_ID" "$HERDR_TAB_ID" "$HERDR_PANE_ID"
herdr workspace list
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
herdr agent list
```

## Sibling pane (same worktree)

Default for same-cwd helpers — not a substitute for main→worktree handoff:

```bash
herdr pane split --current --direction right --cwd "$PWD" --no-focus
herdr pane run <pane-id> "just test"
herdr pane wait-output <pane-id> --match "test result" --timeout 120000
herdr pane read <pane-id> --source recent-unwrapped --lines 120
```

## Agent surface

Target agents by **name or pane id**. Prompting does not require switching the user’s focused workspace.

```bash
herdr agent start reviewer --kind codex --pane <pane-id>
# Prefer rename when sticky layout already launched the agent:
herdr agent rename <pane-id> reviewer
herdr agent prompt reviewer "…" --wait --timeout 120000
herdr agent wait reviewer --until blocked --timeout 120000
herdr agent send-keys reviewer esc
herdr agent read reviewer --source recent-unwrapped --lines 120
```

Prefer `recent-unwrapped` for logs. If alternate-screen output cannot be recovered, ask the agent to write a Markdown file and return only its path (fallback).

### Prompt submit (Cursor)

`herdr agent prompt` is the supported way to start work from the CLI. On Cursor it may only paste into the composer (`Pasted text`) and return `agent_prompt_stalled` while status stays `idle`. Recover with `herdr agent send-keys <name> enter` — do **not** `herdr agent focus` (steals UI). See `resources/handoff.md` / `resources/babysit.md`.

### Focus

- `herdr worktree create|open` / `herdr workspace create` support `--no-focus` for background subspaces.
- Sticky layout create still needs a brief `workspace focus` on the child (plugin invoke has no `--workspace`), then restore the parent.
- `herdr workspace focus` does not accept `--json`.

## Worktrees (grouped subspaces)

```bash
herdr worktree list [--cwd PATH | --workspace ID]
herdr worktree create --cwd <main> --branch NAME [--path PATH] [--label TEXT] --no-focus
herdr worktree open --path PATH|--branch NAME [--label TEXT] --no-focus
herdr worktree remove --workspace ID
```

`worktree create` opens a checkout as a workspace and groups it with the parent repo workspace.

## Safety

- `--no-focus` for background work unless asked to switch
- Parse IDs from JSON; do not invent them
- Do not close what you did not create unless asked
- Never `herdr server stop` / kill the main process unless the user explicitly intends that
