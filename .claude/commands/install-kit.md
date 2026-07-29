# /install-kit

Install or update the kit's global bootstrap in `~/.claude/`. Kit-local (runs from inside the starter-kit repo).

**Two tiers.** Default installs the CONSUMER surface (`_claude-global/` → `commands/work.md`) — what every dev needs. `--maintainer` also installs the MAINTAINER surface (`_claude-maintainer/` → `scripts/sync-starter-kit.sh`, `commands/sync-starter-kit.md`, `kit-maintainer.md`) — only for the one person who syncs the kit into projects. A consumer machine never receives the sync machinery and therefore cannot run a sync.

Idempotent — safe to run on a fresh machine (first-time install) or after changes to `_claude-global/` (ongoing update). Installs missing files, updates differing files, leaves identical files alone.

## When to run

- First time setting up the kit on a new machine
- After editing files in `_claude-global/` or `_claude-maintainer/` — `~/.claude/` is a snapshot, so kit edits do not take effect until this is re-run
- To refresh `~/.claude/starter-kit-config.json` with the current kit path (e.g., after moving the kit repo)

## Procedure

Invoke the script:

```bash
.claude/scripts/install-kit.sh              # consumer: every dev
.claude/scripts/install-kit.sh --maintainer # + maintainer surface: kit maintainer only
```

The script:
1. Verifies we're in the kit (checks `_claude-global/` exists)
2. Walks everything under `_claude-global/` — and under `_claude-maintainer/` too when `--maintainer` is passed
3. For each file, compares hash vs `~/.claude/` equivalent; installs if missing, updates if differs, leaves alone if identical
4. Writes `~/.claude/starter-kit-config.json` with current kit path and timestamp
5. Reports CPL version drift if `_cpl/VERSION` differs from installed version
6. With `--maintainer`: warns if `~/.claude/CLAUDE.md` lacks the `@kit-maintainer.md` import, or if the `~/.claude/kitmaster` marker is missing. It never creates either — a consumer machine must not be able to self-promote. See `kit-maintainer.md`.

## Expected output

Per-file `INSTALLED` / `UPDATED` / `unchanged` lines, plus config-file notice and optional CPL version hint. Non-interactive.

## What this command does NOT do

- Does not install the statusline (`/install-statusline` handles that — one-time)
- Does not build CPL (`/install-cpl` handles that)
- Does not sync project-level config (`_claude-project/` is for consumer projects, consumed via `/sync-starter-kit`)
