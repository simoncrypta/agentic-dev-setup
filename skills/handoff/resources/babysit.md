# After handoff

`handoff-spawn` prints `{label, path, branch, task}` and appends
`~/.local/state/agentic-dev/handoffs.jsonl`. Report that tuple. Inspect a child
only if the user asks.

Example: `Fix-auth_Myapp`, `/home/you/Work/myapp.fix-auth`, `fix-auth`, `refactor auth to JWT`.

```bash
herdr worktree list --cwd "$MAIN"
```

Do not `herdr agent wait`, poll, `herdr agent prompt`, auto-answer approvals, or focus/close a child unless asked. When the user comes back, report the remembered list; escalate `blocked` / hook trust.
