# Project git / Graphite / GitHub (handoff)

The handoff skill is global. Branch/commit/PR tooling is **project-dependent**. Detect once after the child checkout exists; do not assume Graphite or raw git.

## Detection (prefer in order)

A project is a **Graphite repo** when any of these hold in the repo root (shared `.git` works from linked worktrees):

1. `.git/.graphite_repo_config` exists (or `git rev-parse --git-path .graphite_repo_config` resolves to a file)
2. Project Worktrunk hooks mention Graphite, e.g. `.config/wt.toml` contains `gt track` / `graphite-track`
3. Repo agent rules/skills require Graphite (`graphite-stacking`, “use `gt` not `git` for commits”)

Otherwise treat it as a normal **git + gh** repo. `command -v gt` alone is not enough (the CLI may be installed globally).

## After creating a handoff branch / worktree

`herdr worktree create --branch` uses plain git. It does **not** run Worktrunk hooks and does **not** Graphite-track the branch. That is why `gtp` / `gt` fail with “untracked branch”.

### Graphite repos

From the **child** checkout (or `gt --cwd <sibling-path>`):

```bash
# Already tracked? no-op
gt parent >/dev/null 2>&1 && return 0

TRUNK="$(jq -r '.trunk // "main"' "$(git rev-parse --git-path .graphite_repo_config)" 2>/dev/null)"
TRUNK="${TRUNK:-main}"

gt track --parent "$TRUNK" --no-interactive \
  || gt track --force --no-interactive
```

Do this **before** starting the child so `gtp` / `gt submit` / stack nav work.

Prefer creating the worktree via Worktrunk when hooks are approved, so project `graphite-track` runs, then the handoff create block in `resources/handoff.md` (`WT_HERDR_AGENT_PROMPT` + `wt_herdr_layout_create`).

If you must use `herdr worktree create` (or hooks are not approved), still run the `gt track` block above. Never pass Worktrunk `--yes` to bypass approvals for the user.

Include in the child agent prompt (Graphite projects only):

- Use `gt` / Graphite MCP for branch, commit, push, PR — not raw `git commit` / `git push` / `git checkout -b`.
- Do not commit/submit unless the user asked.
- Load the repo’s Graphite skill/rules when present (e.g. `graphite-stacking`).

### Non-Graphite repos

No `gt track`. Child uses normal git/`gh` per the repo’s rules and the global `git-master` skill when committing.

## Commits and PRs

Handoff never auto-commits. When the user later asks to commit/submit:

| Project | Tooling |
|---------|---------|
| Graphite | `gt create` / `gt modify` / `gt submit` (or Graphite MCP `run_gt_cmd`) |
| Otherwise | `git` + `gh` via `git-master` / PR workflows |
