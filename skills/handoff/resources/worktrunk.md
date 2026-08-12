# Worktrunk (condensed, Herdr-adapted)

Worktrunk (`wt`) manages git worktrees. In this layout, Herdr owns the terminal subspaces; prefer Herdr handoffs over tmux/Zellij recipes from upstream Worktrunk docs.

## Two configs

- **User** `~/.config/worktrunk/config.toml` — personal preferences; propose changes, get consent.
- **Project** `<repo>/.config/wt.toml` — team hooks; edit with care; warn on destructive commands.

This layout also uses `~/.config/worktrunk/herdr-layout.sh` and user hooks so `post-start` / `post-remove` open or close Herdr worktree-group children for sibling checkouts.

## Useful commands

```bash
wt config show
wt list --format=json
wt switch --create <branch>
wt switch <branch>
```

Shell wrappers (when installed): `wtc` / `wts` / `wtd` / `dev`.

## Hook approvals

Worktrunk will not run project hooks/aliases until the user approves them. In non-interactive agent sessions, approval prompts fail.

**Escalate to the user** — tell them to run `wt config approvals add`. Do **not** pass `--yes` to bypass approval for the user (`--yes` is for CI that already owns the hook contents).

## Handoffs

Inside Herdr, use the `handoff` skill recipe (`resources/handoff.md`): Worktrunk checkout + `wt_herdr_layout_create` + CLI `herdr agent prompt` (Cursor may need `send-keys enter` after paste). Keep parent focus with `--no-focus` / `WT_HERDR_NO_ATTACH=1`.

For parallel sub-agents in separate worktrees from a parent that cannot consume shell cd scripts:

```bash
# Prefer hooks ON for Graphite projects (project wt.toml may run `gt track`)
wt switch --create <branch> --no-cd
```

Then open the sibling with `wt_herdr_layout_create` (see `resources/handoff.md`). Prefer letting hooks run when you want the Herdr subspace auto-created and Graphite tracking. Only add `--no-hooks` when you intentionally skip project hooks — then run `gt track` yourself if the repo is Graphite (see `resources/git-workflow.md`).

## Do not

- Use `Agent { isolation: "worktree" }` patterns that invent throwaway branch names when Worktrunk + Herdr already define the path/branch.
- Approve hooks on the user’s behalf.
