# Project git / Graphite / GitHub (handoff)

Spawn (`scripts/handoff-spawn --info` then spawn) already reports `graphite`
and Graphite-tracks the sibling when that is true. Do not re-detect. The child
intro already says to use `gt` on Graphite repos.

Handoff never auto-commits. When the user later asks to commit/submit:

| Spawn JSON | Tooling |
|------------|---------|
| `graphite: true` | `gt create` / `gt modify` / `gt submit` (or Graphite MCP `run_gt_cmd`) |
| otherwise | `git` + `gh` via `git-master` / PR workflows |

Do not commit/submit unless the user asked.
