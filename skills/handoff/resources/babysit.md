# Babysit child agents

After one or more handoffs, the parent agent coordinates without stealing the user’s focus.

## Rules

- Create children with `--no-focus` unless the user asked to switch into that workspace.
- Do not close workspaces, tabs, or panes you did not create unless asked.
- Never auto-answer approval / trust UIs — escalate to the user.
- Prefer unique agent names that match the feature (`fix-auth`, `add-billing`).
- Never `herdr agent focus` / `herdr workspace focus` on a child unless the user asks to look at it.

## Fan-out

Repeat the handoff recipe for each feature. Keep a local list of `{name, workspace_id, branch, path}`.

```bash
herdr agent list
herdr worktree list --cwd "$MAIN"
```

## Wait and inspect

```bash
herdr agent wait fix-auth --until blocked --timeout 600000
# or settled idle/done/blocked:
herdr agent wait fix-auth --timeout 600000

herdr agent get fix-auth
herdr agent read fix-auth --source recent-unwrapped --lines 120
```

`blocked` means Herdr saw an approval or question UI. Read the pane, summarize for the user, and only send keys/prompts after they decide.

## `agent_prompt_stalled` recovery

If `herdr agent prompt` returns `agent_prompt_stalled` (or the child stays `idle` with pasted composer text):

1. `herdr agent read <name> --source recent-unwrapped --lines 40`
2. If you see `Pasted text` / an unsubmitted composer, run `herdr agent send-keys <name> enter` (no focus switch).
3. Confirm `herdr agent get <name>` shows `working`.
4. Escalate to the user only if that fails or a real approval/blocker appears.

Do not treat a Cursor paste-without-submit as a user decision.

## When to escalate

- `blocked` / approval prompts / hook trust (`wt config approvals add`)
- Conflicting edits across worktrees that need a product decision
- Failed waits, `unknown` state that does not clear, or stalled prompts that **do not** recover after Enter
- Child asking to merge, push, or destroy worktrees

## When to continue without the user

- Child is `working` — leave it alone
- Child reaches `done` / `idle` with a clear summary — report status; ask if they want review/merge next

## Focus

Keep the parent workspace focused. Use `herdr agent focus` / `herdr workspace focus` only when the user asks to look at a child.
