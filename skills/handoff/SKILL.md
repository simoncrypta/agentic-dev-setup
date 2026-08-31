---
name: handoff
description: >-
  Spawns main-repo to worktree feature handoffs in Herdr via scripts/handoff-spawn:
  sibling worktree, optional dirty copy, sticky layout, cursor-agent with /poteto-mode
  and the original prompt. Any parent agent can call it; the child is always
  cursor-agent. Use when the user asks to hand off, spawn parallel features or
  worktrees. Call by name: handoff.
compatibility: Requires herdr, wt (worktrunk), and the sticky-agent Herdr layout helpers.
---

# handoff

Do not inspect git, Graphite, Herdr, or worktrees yourself. Run `--info`, then spawn.

```bash
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" --info
```

That JSON is the only context you need: `herdr`, `herdr_env`, `socket`,
`main_checkout`, `cwd`, `branch`, `dirty`, `graphite`, `default_copy`,
`helper`, `workspace`.

- If `herdr` is false, report that and stop.
- If `main_checkout` is false, report that and stop (do not spawn from a linked worktree).
- If `herdr_env` is false but `socket` is true, spawn with `--workspace <id>`
  (the parent Herdr workspace to keep focused). Do not split a dummy pane
  just to set `HERDR_ENV`.

Pick a short branch name (`fix-auth`, `jwt-tokens`) and spawn with the
**original user prompt**. Do not rewrite the task.

```bash
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" <branch> [--dirty|--clean] [--plan] [--workspace <id>] <<'EOF'
<original user prompt only>
EOF
```

From a machine shell talking to Herdr over the socket, keep the prompt off the
argv (long `herdr pane run … spawn -- prompt` gets blocked). Write it to a file:

```bash
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" <branch> --clean --workspace "$id" --prompt-file /path/to/prompt.txt
```

- `--dirty` / `--clean` override `default_copy`. Default is dirty when `--info`
  says `dirty: true`. Copy is a working tree (no `git add`).
- `--plan` — add “Plan/design only; do not implement yet.”
- Graphite tracking is inside the script when `graphite` is true. Do not `gt track`.

The script prints one JSON object: `label`, `path`, `branch`, `task`,
`agent_started`, `dirty_copied`, `graphite`. It appends that line to
`~/.local/state/agentic-dev/handoffs.jsonl` whenever the sibling worktree
exists, even if `agent_started` is false.

Report that tuple and stop. If the script exits nonzero before creating a
worktree, report the error and stop. Do not `pane run` the child, `agent prompt`,
paste, send-keys, or focus the child.

## When not to use

- Ordinary coding in the **current** worktree with no handoff.
- Herdr unreachable (`herdr` is false) — the script will refuse spawn.
- Pure Worktrunk config/hook questions — escalate hook approvals to the user.

## Other Herdr / Worktrunk control

Not the spawn path. Use only when the user asks to manage panes, keys, or
existing worktrees: `resources/herdr-control.md`, `resources/worktrunk.md`,
`resources/keys.md`, `resources/babysit.md`. After spawn, Graphite vs git is
already in the spawn JSON and the child intro — do not re-detect.
