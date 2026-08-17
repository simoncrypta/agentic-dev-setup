# Handoff from main (detail)

Use this when spawning a feature worktree from the main checkout inside Herdr.

## Preconditions

- `HERDR_ENV=1`
- Current cwd is the **main** repo checkout (`is_linked_worktree` false in `herdr worktree list`)
- User asked for a new feature / parallel agent / handoff

## Sibling path and label

```text
<main-repo-parent>/<repo>.<branch>
```

Example: `/home/you/Work/myapp` + `fix-auth` → `/home/you/Work/myapp.fix-auth`.
Label (matches helpers): `Branch_Repo`, e.g. `Fix-auth_Myapp` via `_wt_generate_session_name`.

## Create checkout + sticky subspace

Prefer Worktrunk so project hooks run, then the layout helper for Herdr topology:

```bash
MAIN="$PWD"
BRANCH="fix-auth"
PATH_SIBLING="${MAIN}.${BRANCH}"

wt switch --create "$BRANCH" --no-cd
# If checkout already exists: reuse PATH_SIBLING / wt switch

source "$HOME/.config/worktrunk/herdr-layout.sh"
LABEL="$(_wt_generate_session_name "$PATH_SIBLING")"
WT_HERDR_AGENT_PROMPT="$(printf '%s\n\n%s' "$INTRO" "$USER_PROMPT")"
wt_herdr_layout_create "$LABEL" "$PATH_SIBLING" || {
  echo "handoff: wt_herdr_layout_create failed; stop. Do not start the child another way." >&2
  return 1
}
```

`wt_herdr_layout_create` owns:

- `herdr worktree open|create --path` for linked checkouts (group under main)
- sticky `agentic-dev.dev-layout.create` via the plugin script (not `plugin action invoke`)
- forwarding `WT_HERDR_AGENT_PROMPT` so plugin create can `herdr agent prompt` after the TUI is detected
- keeping whatever workspace the user is already viewing (create does not focus the child, the parent, or the helper's own pane)

Worktrunk `post-start` also calls `wt_herdr_layout_create`, but it **unsets**
`WT_HERDR_AGENT_PROMPT` first so a parent agent shell cannot leak the task into
layout-only create. Only this handoff recipe should submit the prompt.

Human/shell: `wtc <branch>` (same hooks + helper).

Do **not** duplicate that topology with a hand-rolled `worktree create` + plugin sequence.

### Graphite / project git

`herdr worktree create` alone does not Graphite-track. Prefer `wt switch --create` when hooks are approved. Otherwise track explicitly — `resources/git-workflow.md`.

## Prompt wrap and plan

Intro is one line. Keep the **original user prompt** unchanged after it.

```text
You are in linked worktree <path> (branch <branch>). Stay in this checkout.
```

Graphite repos only, add: `Use gt, not raw git commit/push, unless asked.` — `resources/git-workflow.md`.

If the user asked to plan/design/explore, add that to the intro (for example
`Plan/design only; do not implement yet.`). Plugin create already starts the
agent TUI, so CLI plan flags cannot be added afterward.

Set `INTRO` to the one-liner above and `USER_PROMPT` to the original user text
only. Do not attach transcripts, debugger dumps, or tool JSON. Pass both via
`WT_HERDR_AGENT_PROMPT` on `wt_herdr_layout_create` (see above). If the helper
exits nonzero, report that failure and stop; do not invent a second start.
Do **not** `herdr pane run` after create, do not `workspace focus` / `agent focus`
/ `session attach`, and do not paste or `pane send-keys` into the child TUI.
Do not send a second `herdr agent prompt` after the helper returns.

## After handoff

Stay on whatever workspace the user is viewing. Remember `{label, path, branch, one-line task}` — `resources/babysit.md`.
