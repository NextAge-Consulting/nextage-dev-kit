# Worktree Protocol

**The only verb you type to enter or create a worktree is `/work`.** Never call the `EnterWorktree` tool directly. This rule is enforced by the `worktree-guard.sh` PostToolUse hook (advisory reminder) plus the model below.

## The model

All Claude-driven editing happens inside a git worktree under `<project>/.claude/worktrees/`. The primary repo folder always sits on `main`, clean — it is reserved for git substrate and for plain-CLI workflows (e.g. `/sync-dev-kit`) that expect a clean `main` checkout. One body of work → one worktree → one branch → one PR.

`/work` is the only authorized entry point. Re-entering an existing worktree, creating a new one off `origin/main`, retrieving a teammate's branch, opening a parallel compartment — all of them route through `/work`. The script handles `git worktree add`, the `EnterWorktree` tool call, and (critically) the setup steps below.

## Why direct `EnterWorktree` is forbidden

Claude Code's background-session system prompt nudges Claude toward calling `EnterWorktree(name=...)` directly to satisfy its edit-isolation guard. That call MAY trigger the binary's built-in symlinkPaths/symlinkDirectories/postCreate logic — but in practice it's unreliable across versions: the worktree gets created while the symlinks and postCreate steps are silently skipped, leaving the dev server without `.env` and tests without `node_modules`.

`/work` bypasses the binary's built-in path entirely. It does `git worktree add` directly, then runs two helpers that read the same `.worktree.*` settings as the binary would have, but in shell so the behavior is deterministic across Claude Code versions:

1. **`apply_worktree_symlinks`** — reads `.worktree.symlinkPaths` (files like `.env`) and `.worktree.symlinkDirectories` (dirs like `.venv`), creates absolute-target symlinks from primary into the worktree. Idempotent — also runs on re-entry to heal missing symlinks.
2. **`run_post_create`** — reads `.worktree.postCreate` (commands like `["npm ci"]`), runs each inside the new worktree. Fires only on create, not re-entry.

The harness's `worktree.bgIsolation: "none"` setting (in `.claude/settings.json`) removes the edit-time enforcement of `EnterWorktree`, so `/work` can be the entry point without the harness blocking the first edit.

## The procedure

| Situation | Type |
|---|---|
| Starting work in a project | `/work` |
| Starting work tied to a GitHub issue | `/work <issue#>` |
| Need a parallel compartment | `/work --new <name>` |
| Pulling a teammate's branch | `/work --retrieve <branch>` |
| Re-entering after a session break | `/work` (idempotent — re-enters `current/`) |
| Done with a compartment | `/work --discard <name>` |

After `/work` returns, your tool-process cwd is inside the worktree. All edits land there.

**Surface the stale-dev-server gap on entry.** A dev server that was already running was started against the primary checkout — it serves stale code until it's restarted from the worktree. On `/work`, say so immediately so the human isn't testing against old code.

**Commands you hand the human embed the worktree `cd`.** Your cwd is the worktree, but the human's terminal sits in primary/main. Any shell command you give them to run must embed the absolute `cd <worktree>` (or use the `!` prefix so it runs in-session) — otherwise it executes in the wrong tree.

## The hook

`.claude/hooks/worktree-guard.sh` fires on `PostToolUse` for `EnterWorktree`. It runs only when called in create-mode (with a `name` parameter); path-mode (entering an existing worktree, which is `/work`'s authorized pattern) is silently skipped. On create-mode it injects a system-reminder telling Claude to verify the setup steps ran — checking `.env` is symlinked and `node_modules` is populated — or run the `apply_worktree_symlinks` + `run_post_create` helpers from `.claude/skills/gitflow/scripts/work.sh` manually, or exit and re-enter via `/work`.

The hook does NOT block. It is advisory because (a) the system prompt actively pushes toward `EnterWorktree`, (b) blocking would force Claude to fight the harness, and (c) the failure mode (half-built worktree) is recoverable post-hoc.

## When the rule applies

- Every coding session, regardless of surface (standalone CLI, agents view, Claude Cloud)
- Every background-job invocation
- Both create and re-entry — `/work` covers both

## When the rule does NOT apply

- Plain-CLI workflows that operate against primary by design (`/sync-dev-kit`) — these expect to run against `main` in the primary checkout, not in a worktree
- **`/ship-main` — the sanctioned direct-to-main exception.** Quick infra / config / emergency work is done in the primary repo on `main` and committed straight there via `/ship-main` (no branch, no PR, no worktree). The worktree's only value is an isolated runtime feedback loop for application code; infra YAML / Dockerfiles / workflow edits have no such loop, so the worktree is friction without benefit. `/ship-main` is the explicit, by-name verb for this — never inferred (a bare `/commit` on `main` still auto-branches). See `commands/ship-main.md`.
- Read-only inspection of the primary (running `git status`, `git log`, etc.) when you just need to see substrate state

## Recovery: I called EnterWorktree directly and got a half-built worktree

1. Confirm: `ls -la <worktree>/.env` — if it doesn't show `-> <primary>/.env`, the symlink is missing.
2. Confirm: `ls <worktree>/node_modules | head -1` — if empty, postCreate didn't run.
3. Fix option A (canonical): `ExitWorktree({action:"keep"})` then `/work` — re-enters via the canonical path, which heals missing symlinks on re-entry and (if create was incomplete) re-runs postCreate.
4. Fix option B (manual): from inside the worktree, source `work.sh` and call its helpers against the current path. Idempotent.
