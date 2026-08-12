---
name: handoff
description: >-
  Spawns main-repo to worktree feature handoffs in Herdr: opens a sibling worktree subspace,
  applies the sticky-agent layout, starts a child agent with the task prompt, and babysits for
  blocked or attention states. Also covers Herdr pane/agent control and Worktrunk (wt) for that
  stack. Use when the user asks to hand off, spawn parallel features or worktrees, babysit child
  agents, or manage Herdr/Worktrunk in this layout. Call by name: handoff.
compatibility: Requires herdr, wt (worktrunk), and the sticky-agent Herdr layout helpers.
---

# handoff

Primary job: from the **main checkout** inside Herdr, open a **new feature worktree** as a Herdr
worktree-group child (subspace), start the sticky-agent layout there with the task already
prompted, keep focus on the parent, and **babysit** until the user is needed.

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
   Sibling path is typically `<main>.<branch>`. Label: `Repo_Branch`.  
   **Project git**: Graphite-track when needed — `resources/git-workflow.md`.
3. Open sticky layout via the installed helper (owns worktree grouping + layout + focus restore):

```bash
source "$HOME/.config/worktrunk/herdr-layout.sh"
LABEL="$(_wt_generate_session_name "$PATH_SIBLING")"
WT_HERDR_NO_ATTACH=1 wt_herdr_layout_create "$LABEL" "$PATH_SIBLING"
```

Do **not** hand-roll `herdr worktree create|open` + plugin focus thrash; the helper is the single topology path.

4. Resolve the child workspace / sticky agent pane (`herdr pane list --workspace …`). Prefer `herdr agent rename` if the pane already has the layout agent; only `herdr agent start` when it is still a shell. Kind from `~/.config/agentic-dev/config.toml`: `agent`→`cursor`, `codex`, `opencode`, `claude`.
5. From the parent: `herdr agent prompt <name> "<task>"` (no focus steal). On Cursor `agent_prompt_stalled`, `herdr agent send-keys <name> enter` then babysit. Graphite repos: tell the child to use `gt`, not raw commit/push, unless asked.
6. On `blocked`, read context and **ask the user** before approvals.

Details: `resources/handoff.md`. Git/Graphite/gh: `resources/git-workflow.md`.

## Babysit

Fan out many children. Track with `herdr agent list` / `herdr agent wait <name> --until blocked`. Escalate approvals to the user. Recover Cursor stalls with Enter (`resources/babysit.md`). Do not steal focus unless asked.

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
