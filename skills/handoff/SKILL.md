---
name: handoff
description: >-
  Spawns main-repo to worktree feature handoffs in Herdr: names a short branch, opens a sibling
  worktree subspace, applies the sticky-agent layout, starts the configured agent (`agent` for Cursor, `grok`, `pi`, …), and
  remembers where it is. Also covers Herdr pane control and Worktrunk (wt) for that stack. Use
  when the user asks to hand off, spawn parallel features or worktrees, or manage Herdr/Worktrunk
  in this layout. Call by name: handoff.
compatibility: Requires herdr, wt (worktrunk), and the sticky-agent Herdr layout helpers.
---

# handoff

Primary job: from the **main checkout** inside Herdr, open a **new feature worktree** as a Herdr
worktree-group child (subspace), start the sticky-agent layout, launch the child with the user's
prompt, leave the user's current Herdr workspace focused, and **remember** `{label, path, branch, task}`.

Parent work is only:

1. Pick a short branch/worktree name from the user's ask (`fix-auth`, `jwt-tokens`).
2. Wrap the **original user prompt** with a one-line intro. Do not rewrite the task.
3. If the user asked to plan/design/explore, say so in the intro. Layout create
   already starts the agent TUI, so CLI plan flags cannot be added afterward.
4. Create the sibling, open layout, submit the prompt, stop.

Secondary: enough Herdr + Worktrunk control to run that workflow. Details live in `resources/`.

## Safety

Before any Herdr control command:

```bash
test "${HERDR_ENV:-}" = 1
```

If that fails, say you are not inside a Herdr-managed pane and stop controlling the session.

## Handoff from main (primary recipe)

1. Confirm you are on the **main** checkout (not a linked worktree): `herdr worktree list --cwd "$PWD"`.
2. Create the sibling checkout (prefer Worktrunk so hooks run):
   `wt switch --create <branch> --no-cd`
   or human/shell: `wtc <branch>`.
   Sibling path is typically `<main>.<branch>`. Label: `Branch_Repo` (e.g. `Fix-auth_Myapp`).
   **Project git**: Graphite-track when needed — `resources/git-workflow.md`.
3. Open sticky layout via the installed helper. Pass the prompt so plugin create
   starts the agent TUI and submits it with `herdr agent prompt`:

```bash
source "$HOME/.config/worktrunk/herdr-layout.sh"
LABEL="$(_wt_generate_session_name "$PATH_SIBLING")"
WT_HERDR_AGENT_PROMPT="$(printf '%s\n\n%s' "$INTRO" "$USER_PROMPT")"
wt_herdr_layout_create "$LABEL" "$PATH_SIBLING" || {
  echo "handoff: wt_herdr_layout_create failed; stop. Do not start the child another way." >&2
  return 1
}
```

`USER_PROMPT` is the original user text only. Do not attach transcripts, debugger dumps, or tool JSON.

Do **not** hand-roll `herdr worktree create|open` + plugin focus thrash; the helper is the single topology path. Do **not** `herdr pane run` after create (the agent TUI is already running). Do **not** `workspace focus`, `agent focus`, `session attach`, `pane send-keys` / `send-input`, or paste into the child TUI. Leave the user's current Herdr workspace focused — not the child, not the parent, not this pane. The only submit path is `WT_HERDR_AGENT_PROMPT` on `wt_herdr_layout_create` (plugin create runs `herdr agent prompt`). Do not race a second `herdr agent prompt` after the helper returns. If the helper exits nonzero, report that failure and stop; do not switch to the child or paste the task.

4. Remember `{label, path, branch, one-line task}` and stop.

Details: `resources/handoff.md`. Git/Graphite/gh: `resources/git-workflow.md`. After handoff: `resources/babysit.md`.

## Herdr + Worktrunk

- Herdr control: `resources/herdr-control.md` (`herdr --help` / `herdr --skill` when available).
- Worktrunk: `resources/worktrunk.md`. Never `--yes` hook approvals for the user.
- Shell: `wtc` / `wts` / `wtd` / `dev` / `d` / `t`.
- Keyboard questions only: `resources/keys.md`.

Do **not** use tmux/Zellij handoff recipes when Herdr is available.

## When not to use

- Ordinary coding in the **current** worktree with no handoff or orchestration.
- Herdr control when `HERDR_ENV` is unset.
- Pure Worktrunk config/hook questions with no Herdr session — escalate approvals to the user.
