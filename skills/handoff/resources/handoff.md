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
Label (matches helpers): `Repo_Branch`, e.g. `Myapp_Fix-auth` via `_wt_generate_session_name`.

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
WT_HERDR_NO_ATTACH=1 wt_herdr_layout_create "$LABEL" "$PATH_SIBLING"
```

`wt_herdr_layout_create` owns:

- `herdr worktree open|create --path` for linked checkouts (group under main)
- sticky `agentic-dev.dev-layout.create`
- restoring the previously focused workspace (parent stays in view)

Human/shell: `wtc <branch>` (same hooks + helper).

Do **not** duplicate that topology with a hand-rolled `worktree create` + focus + plugin + restore sequence.

Find the child workspace id (label or path):

```bash
CHILD_WS="$(herdr workspace list | jq -r --arg l "$LABEL" \
  '.result.workspaces[] | select(.label == $l) | .workspace_id' | head -1)"
```

### Graphite / project git

`herdr worktree create` alone does not Graphite-track. Prefer `wt switch --create` when hooks are approved. Otherwise track explicitly — `resources/git-workflow.md`.

## Bind agent + prompt

Poll until the sticky agent pane exists (layout create can be briefly async):

```bash
for _ in 1 2 3 4 5 6 7 8 9 10; do
  herdr pane list --workspace "$CHILD_WS" | jq -e '
    .result.panes[] | select(.agent != null and .agent != "")
  ' >/dev/null 2>&1 && break
  sleep 1
done
AGENT_PANE="$(herdr pane list --workspace "$CHILD_WS" | jq -r '
  .result.panes[] | select(.agent != null and .agent != "") | .pane_id' | head -1)"
```

Kind from `~/.config/agentic-dev/config.toml`: `agent`→`cursor`, `codex`, `opencode`, `claude`.

Prefer rename when the layout agent is already running:

```bash
NAME="fix-auth"   # [a-z][a-z0-9_-]{0,31}
herdr agent rename "$AGENT_PANE" "$NAME"
# Else shell-only pane:
# herdr agent start "$NAME" --kind cursor --pane "$AGENT_PANE"
```

Prompt from the parent — no `herdr agent focus`:

```bash
herdr agent prompt "$NAME" "Implement fix-auth: <task>. Stay in this worktree." --wait --timeout 120000
```

### Cursor prompt stall

If inject shows pasted text but stays `idle` (`agent_prompt_stalled`):

```bash
herdr agent send-keys "$NAME" enter
```

Then babysit (`resources/babysit.md`).

## Kind mapping

| config `command` | `--kind` |
|------------------|----------|
| `agent` | `cursor` |
| `codex` | `codex` |
| `opencode` | `opencode` |
| `claude` | `claude` |

## After handoff

Stay on the parent. Track via `herdr agent list` / `herdr worktree list --cwd "$MAIN"`.
