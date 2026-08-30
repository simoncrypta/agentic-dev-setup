---
name: review
description: >-
  Open the Herdr Review pane (hunk diff), wait for human comments in hunk, address
  them, then close Review. Use after a coherent unit of work (tests pass, before
  commit/PR), when the user asks to review, or when the handoff intro says to.
  Not at session start and not after every file write.
compatibility: Requires Herdr (HERDR_ENV=1), the agentic-dev.layout plugin, and hunk.
---

# review

Open hunk in the Review tab when a changeset is ready for the human, wait for
their comments, fix them, close the tab. Do not leave Review open by default.

## When

- After a coherent unit of work (implementation + tests), before commit/PR.
- When the user asks to review.
- Not at session start. Not after every file write.

## Guard

```bash
test "${HERDR_ENV:-}" = 1
```

If that fails, tell the user to press `prefix+2` (Ctrl-Space then 2) and wait
for them to say comments are ready. Do not run `hunk diff` in this pane.

## Recipe

1. Open (or focus) Review:

```bash
herdr plugin action invoke agentic-dev.layout.select-review
```

2. Load hunk's own session skill (do not copy its flags here):

```bash
hunk skill path
```

Use `hunk session *` against `--repo .` (or this worktree). Optional: navigate,
add agent notes, highlight.

3. Wait for human notes (`c` in hunk) or for hunk to quit (`q`):

```bash
"$HOME/.agents/skills/review/scripts/wait-comments.sh" --repo . --timeout 600
```

| Exit | Meaning | Next |
|------|---------|------|
| 0 | New user comments on stdout (JSON) | Address them, then wait again or close |
| 2 | Live session gone (user quit hunk) | Review ended; close leftover tab if needed |
| 124 | Timeout | Leave Review open; ask the user |

Retry with network/sandbox escalation if loopback `127.0.0.1:47657` is blocked.

4. After the round, close Review (docks stickies back to Shell):

```bash
herdr plugin action invoke agentic-dev.layout.close-review
```

Reopen later with step 1. The human can also `prefix+2` / `prefix+k`.

## Do not

- Run `hunk diff` / `hunk show` in the agent pane (the TUI is for the user).
- Open Review on every edit.
- Restate hunk session CLI flags; `hunk skill path` is the source of truth.
