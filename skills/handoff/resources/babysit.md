# After handoff

Remember `{label, path, branch, one-line task}` and stop. Inspect a child only if the user asks.

Example: `Fix-auth_Myapp`, `/home/you/Work/myapp.fix-auth`, `fix-auth`, `refactor auth to JWT`.

```bash
herdr worktree list --cwd "$MAIN"
```

Do not `herdr agent wait`, poll, `herdr agent prompt`, auto-answer approvals, or focus/close a child unless asked. When the user comes back, report the remembered list; escalate `blocked` / hook trust.
